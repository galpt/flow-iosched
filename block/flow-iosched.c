// SPDX-License-Identifier: GPL-2.0
/*
 * Multi-Lane I/O Scheduler (FLOW) — v3.2 LSB
 *
 * Per-lane starvation-bounded dispatch via bypass_count / starvation_max
 * counters, generalising mq-deadline's writes_starved to N lanes.
 *
 * Key differences from v3.1 LSB:
 *  - One request per dispatch_request() call, matching the blk-mq contract
 *    that all other I/O schedulers (mq-deadline, kyber, BFQ) obey.
 *    Previously flow_fill_dispatch_locked() dequeued up to 24 requests
 *    into an internal staging list per call, which (a) violated the
 *    one-request contract, (b) pushed starvation counters ahead of
 *    actual submission, and (c) hid requests from the hctx->dispatch
 *    drain path on requeue.
 *  - flow_has_work() no longer acquires fd->lock; uses lock-free hints
 *    consistent with all other blk-mq schedulers.
 *  - q->async_depth initialised in init_sched; limit_depth() uses the
 *    standard data->q->async_depth directly instead of a hand-rolled
 *    sbitmap-scaled computation.
 *  - flow_free_sched_data() is empty (all cleanup done in exit_sched),
 *    matching the mq-deadline and BFQ pattern and fixing a double-free
 *    on elevator switch.
 *  - flow_insert_request() returns false when rq->elv.priv[0] is NULL
 *    (mempool exhaustion in prepare_request), so the request is
 *    terminated with BLK_STS_IOERR instead of being silently dropped.
 *
 * ~630 lines, auditable in a single sitting.
 */

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/compiler.h>
#include "elevator.h"
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mempool.h>
#include <linux/module.h>
#include <linux/rbtree.h>
#include <linux/sbitmap.h>
#include <linux/slab.h>
#include <linux/version.h>
#include "blk.h"
#include "blk-mq.h"
#include "blk-mq-sched.h"

#define FLOW_VERSION "3.2"

enum flow_lane {
	FLOW_LANE_EMERGENCY	= 0,
	FLOW_LANE_READ		= 1,
	FLOW_LANE_WRITE		= 2,
	FLOW_NR_LANES		= 3,
};

#define FLOW_QUANTUM_SHIFT		20
#define FLOW_STARVATION_MAX_DEF_R	5U
#define FLOW_STARVATION_MAX_DEF_W	20U
#define FLOW_BATCH_MAX_READ_DEF		16
#define FLOW_BATCH_MAX_WRITE_DEF	16
#define FLOW_MAX_INSERTS		72
#define FLOW_ASYNC_DEPTH_RATIO		3

struct flow_rq_data {
	struct list_head	dl_node;
	struct dl_group		*dl_group;
	struct request		*rq;
	u64			deadline;
	u32			block_size;
	u8			lane;
};

struct dl_group {
	struct rb_node		node;
	struct list_head	rqs;
	u64			deadline;
	u8			lane;
};

struct flow_data {
	struct list_head	prio_queue[2];
	struct rb_root_cached	read_root, write_root, merge_root;
	u32			starvation_max[FLOW_NR_LANES];
	u16			batch_max_read, batch_max_write;
	s8			read_priority;
	mempool_t		*rq_data_pool, *dl_group_pool;
	struct kmem_cache	*rq_data_cache, *dl_group_cache;
	bool			is_rotational;
	sector_t		head_pos;
	struct request_queue	*queue;
	spinlock_t		lock;
};

/*
 * Per-hctx state.  bypass_count[] tracks consecutive dispatch cycles in
 * which the opposite lane was served; when it reaches starvation_max[] the
 * starving lane is force-dispatched.  batch_remaining[] implements the
 * batch-continuity hint (same lane up to batch_max) across consecutive
 * dispatch_request() calls from the blk-mq dispatch loop.
 */
struct flow_hctx_data {
	u32			bypass_count[FLOW_NR_LANES];
	u16			batch_remaining[FLOW_NR_LANES];
	struct blk_mq_hw_ctx	*hctx;
};

static inline struct flow_rq_data *get_rq_data(struct request *rq)
{
	return rq->elv.priv[0];
}

static inline bool rq_is_sync_read(struct request *rq)
{
	return (req_op(rq) == REQ_OP_READ) && (rq->cmd_flags & REQ_SYNC);
}

static u64 flow_deadline(struct request *rq, u8 lane)
{
	if (lane == FLOW_LANE_READ) {
		if (req_op(rq) != REQ_OP_READ && blk_rq_bytes(rq) <= 4096)
			return rq->start_time_ns + (2ULL * NSEC_PER_MSEC);
		return rq->start_time_ns;
	}
	return rq->start_time_ns + (2000ULL * NSEC_PER_MSEC);
}

static u8 flow_assign_lane(struct request *rq, blk_insert_t flags,
			   struct flow_data *fd)
{
	if (flags & BLK_MQ_INSERT_AT_HEAD)
		return FLOW_LANE_EMERGENCY;
	if (rq_is_sync_read(rq) || (rq->cmd_flags & (REQ_META | REQ_PRIO)))
		return FLOW_LANE_READ;
	if ((rq->cmd_flags & REQ_SYNC) || blk_rq_bytes(rq) <= 4096)
		return FLOW_LANE_READ;
	return FLOW_LANE_WRITE;
}

static struct rb_root_cached *flow_root(struct flow_data *fd, u8 lane)
{
	if (lane == FLOW_LANE_READ)
		return &fd->read_root;
	if (lane == FLOW_LANE_WRITE)
		return &fd->write_root;
	return NULL;
}

static bool flow_add_to_dl_tree(struct flow_data *fd, u8 lane,
				struct request *rq)
{
	struct rb_root_cached *root = flow_root(fd, lane);
	struct rb_node **link = &root->rb_root.rb_node, *parent = NULL;
	struct flow_rq_data *rd = get_rq_data(rq);
	struct dl_group *dlg, *new_dlg;
	bool leftmost = true;
	u64 deadline;

	lockdep_assert_held(&fd->lock);
	if (!root || !rd)
		return false;
	rd->lane = lane;
	rd->deadline = flow_deadline(rq, lane);
	rd->block_size = blk_rq_bytes(rq);
	rd->dl_group = NULL;
	deadline = rd->deadline & ~((1ULL << FLOW_QUANTUM_SHIFT) - 1);
	new_dlg = mempool_alloc(fd->dl_group_pool, GFP_ATOMIC);
	if (!new_dlg)
		return false;
	while (*link) {
		dlg = rb_entry(*link, struct dl_group, node);
		parent = *link;
		if ((s64)(deadline - dlg->deadline) < 0) {
			link = &(*link)->rb_left;
		} else if ((s64)(deadline - dlg->deadline) > 0) {
			link = &(*link)->rb_right;
			leftmost = false;
		} else {
			mempool_free(new_dlg, fd->dl_group_pool);
			goto found;
		}
	}
	dlg = new_dlg;
	dlg->deadline = deadline;
	dlg->lane = lane;
	INIT_LIST_HEAD(&dlg->rqs);
	rb_link_node(&dlg->node, parent, link);
	rb_insert_color_cached(&dlg->node, root, leftmost);
found:
	rd->dl_group = dlg;
	list_add_tail(&rd->dl_node, &dlg->rqs);
	return true;
}

static void flow_del_from_dl_tree(struct flow_data *fd, u8 lane,
				  struct request *rq)
{
	struct flow_rq_data *rd = get_rq_data(rq);
	struct dl_group *dlg;

	lockdep_assert_held(&fd->lock);
	if (!rd || !rd->dl_group || list_empty(&rd->dl_node))
		return;
	dlg = rd->dl_group;
	rd->dl_group = NULL;
	list_del_init(&rd->dl_node);
	if (list_empty(&dlg->rqs)) {
		rb_erase_cached(&dlg->node, flow_root(fd, lane));
		mempool_free(dlg, fd->dl_group_pool);
	}
}

static struct request *flow_first_rq(struct flow_data *fd, u8 lane)
{
	struct rb_root_cached *root = flow_root(fd, lane);
	struct rb_node *node;

	if (!root)
		return NULL;
	node = rb_first_cached(root);
	if (!node)
		return NULL;
	return list_first_entry(&rb_entry(node, struct dl_group, node)->rqs,
				struct flow_rq_data, dl_node)->rq;
}

static struct request *flow_former_request(struct request_queue *q,
					   struct request *rq)
{
	struct rb_node *prev = rb_prev(&rq->rb_node);

	return prev ? rb_entry_rq(prev) : NULL;
}

static struct request *flow_next_request(struct request_queue *q,
					 struct request *rq)
{
	struct rb_node *next = rb_next(&rq->rb_node);

	return next ? rb_entry_rq(next) : NULL;
}

static void flow_remove_request(struct flow_data *fd, struct request *rq,
				struct request_queue *q)
{
	struct flow_rq_data *rd = get_rq_data(rq);

	lockdep_assert_held(&fd->lock);
	if (rd && !list_empty(&rd->dl_node))
		flow_del_from_dl_tree(fd, rd->lane, rq);
	if (rq_mergeable(rq))
		elv_rb_del(&fd->merge_root.rb_root, rq);
	list_del_init(&rq->queuelist);
	elv_rqhash_del(q, rq);
	if (q->last_merge == rq)
		q->last_merge = NULL;
}

static bool flow_insert_request(struct blk_mq_hw_ctx *hctx,
				struct request *rq, blk_insert_t flags,
				struct list_head *free)
{
	struct flow_data *fd = hctx->queue->elevator->elevator_data;
	struct flow_rq_data *rd = get_rq_data(rq);
	u8 lane;

	lockdep_assert_held(&fd->lock);

	/*
	 * mempool exhaustion in flow_prepare_request leaves priv[0] NULL.
	 * Return failure so the caller terminates the request cleanly
	 * rather than silently dropping it.
	 */
	if (!rd)
		return false;

	rd->block_size = blk_rq_bytes(rq);
	if (blk_mq_sched_try_insert_merge(hctx->queue, rq, free))
		return true;
	lane = flow_assign_lane(rq, flags, fd);
	WRITE_ONCE(rd->lane, lane);
	if (lane == FLOW_LANE_EMERGENCY) {
		list_add_tail(&rq->queuelist, &fd->prio_queue[0]);
	} else if (!flow_add_to_dl_tree(fd, lane, rq)) {
		return false;
	}
	if (rq_mergeable(rq)) {
		elv_rb_add(&fd->merge_root.rb_root, rq);
		elv_rqhash_add(hctx->queue, rq);
		if (!hctx->queue->last_merge)
			hctx->queue->last_merge = rq;
	}
	return true;
}

static void flow_insert_requests(struct blk_mq_hw_ctx *hctx,
				 struct list_head *list,
				 blk_insert_t flags)
{
	struct flow_data *fd = hctx->queue->elevator->elevator_data;
	struct request *rq, *tmp;
	LIST_HEAD(free);
	LIST_HEAD(fail);
	bool stop;

	do {
		stop = false;
		scoped_guard(spinlock_irqsave, &fd->lock)
		for (int i = 0; i < FLOW_MAX_INSERTS; i++) {
			if (list_empty(list)) { stop = true; break; }
			rq = list_first_entry(list, struct request, queuelist);
			list_del_init(&rq->queuelist);
			if (!flow_insert_request(hctx, rq, flags, &free))
				list_add_tail(&rq->queuelist, &fail);
		}
	} while (!stop);
	blk_mq_free_requests(&free);
	list_for_each_entry_safe(rq, tmp, &fail, queuelist) {
		list_del_init(&rq->queuelist);
		blk_mq_end_request(rq, BLK_STS_IOERR);
	}
}

static void flow_prepare_request(struct request *rq)
{
	struct flow_data *fd = rq->q->elevator->elevator_data;
	struct flow_rq_data *rd;

	if (!fd)
		return;
	rd = mempool_alloc(fd->rq_data_pool, GFP_ATOMIC);
	if (!rd)
		return;
	memset(rd, 0, sizeof(*rd));
	rd->rq = rq;
	INIT_LIST_HEAD(&rd->dl_node);
	rq->elv.priv[0] = rd;
}

static void flow_finish_request(struct request *rq)
{
	struct flow_data *fd = rq->q->elevator->elevator_data;

	if (rq->elv.priv[0]) {
		mempool_free(get_rq_data(rq), fd->rq_data_pool);
		rq->elv.priv[0] = NULL;
	}
}

/*
 * requeue_request is a no-op: once a request has been removed from the
 * scheduler's data structures (in flow_dispatch_request), any requeue
 * (e.g. BLK_STS_RESOURCE) is handled by the blk-mq core which moves it
 * to hctx->dispatch.  The per-request metadata remains valid through
 * eventual completion / finish_request.  This matches the behaviour of
 * mq-deadline.
 */
static void flow_requeue_request(struct request *rq) { (void)rq; }

/*
 * Select the dispatch lane via starvation-bound + batch logic.
 *
 * Priority:
 *  1. Starving write lane  (bypass_count[W] >= starvation_max[W])
 *  2. Starving read lane   (bypass_count[R] >= starvation_max[R])
 *  3. Normal read batch    (batch_remaining[R] > 0)
 *  4. New read batch       (first read in a group)
 *  5. Normal write batch   (batch_remaining[W] > 0)
 *  6. New write batch      (first write in a group)
 *  7. FLOW_NR_LANES        (no work)
 *
 * batch_remaining tracks continuity across dispatch_request() calls on
 * the same hctx, avoiding gratuitous lane switching within batch_max.
 */
static u8 flow_select_lane(struct flow_data *fd, struct flow_hctx_data *khd)
{
	u32 *bc = khd->bypass_count;

	lockdep_assert_held(&fd->lock);

	/* 1. Starvation overrides — check lower-priority lane first */
	if (bc[FLOW_LANE_WRITE] >= fd->starvation_max[FLOW_LANE_WRITE] &&
	    flow_first_rq(fd, FLOW_LANE_WRITE))
		return FLOW_LANE_WRITE;

	if (bc[FLOW_LANE_READ] >= fd->starvation_max[FLOW_LANE_READ] &&
	    flow_first_rq(fd, FLOW_LANE_READ))
		return FLOW_LANE_READ;

	/* 2. Continue existing batch or start a new one */
	if (khd->batch_remaining[FLOW_LANE_READ] > 0 &&
	    flow_first_rq(fd, FLOW_LANE_READ)) {
		khd->batch_remaining[FLOW_LANE_READ]--;
		return FLOW_LANE_READ;
	}

	if (flow_first_rq(fd, FLOW_LANE_READ)) {
		khd->batch_remaining[FLOW_LANE_READ] =
			fd->batch_max_read - 1;
		khd->batch_remaining[FLOW_LANE_WRITE] = 0;
		return FLOW_LANE_READ;
	}

	if (khd->batch_remaining[FLOW_LANE_WRITE] > 0 &&
	    flow_first_rq(fd, FLOW_LANE_WRITE)) {
		khd->batch_remaining[FLOW_LANE_WRITE]--;
		return FLOW_LANE_WRITE;
	}

	if (flow_first_rq(fd, FLOW_LANE_WRITE)) {
		khd->batch_remaining[FLOW_LANE_WRITE] =
			fd->batch_max_write - 1;
		khd->batch_remaining[FLOW_LANE_READ] = 0;
		return FLOW_LANE_WRITE;
	}

	return FLOW_NR_LANES;
}

/*
 * Update starvation counters after dispatching a request from @lane.
 *
 * When a lane was force-dispatched because its bypass_count reached
 * starvation_max, all counters (and batch state) are reset — the
 * anti-starvation debt is paid.  Otherwise the opposite lane's bypass
 * counter is incremented.
 */
static void flow_update_starvation(struct flow_data *fd,
				   struct flow_hctx_data *khd, u8 lane)
{
	u32 *bc = khd->bypass_count;

	lockdep_assert_held(&fd->lock);

	if ((lane == FLOW_LANE_WRITE &&
	     bc[FLOW_LANE_WRITE] >= fd->starvation_max[FLOW_LANE_WRITE]) ||
	    (lane == FLOW_LANE_READ &&
	     bc[FLOW_LANE_READ] >= fd->starvation_max[FLOW_LANE_READ])) {
		/* Starvation serviced — reset everything */
		bc[FLOW_LANE_READ] = 0;
		bc[FLOW_LANE_WRITE] = 0;
		khd->batch_remaining[FLOW_LANE_READ] = 0;
		khd->batch_remaining[FLOW_LANE_WRITE] = 0;
	} else if (lane == FLOW_LANE_READ) {
		bc[FLOW_LANE_WRITE]++;
	} else {
		bc[FLOW_LANE_READ]++;
	}
}

/*
 * Dispatch exactly one request, obeying the blk-mq dispatch contract
 * that all stable I/O schedulers (mq-deadline, kyber, BFQ) follow.
 *
 * Returns NULL when no work is available; the blk-mq dispatch loop
 * (__blk_mq_do_dispatch_sched) handles the budget release.
 */
static struct request *flow_dispatch_request(struct blk_mq_hw_ctx *hctx)
{
	struct flow_data *fd = hctx->queue->elevator->elevator_data;
	struct flow_hctx_data *khd = hctx->sched_data;
	struct request *rq;
	u8 lane;

	guard(spinlock_irqsave)(&fd->lock);

	/* 1. Priority queues drained unconditionally before rbtrees */
	for (int i = 0; i < 2; i++)
		if (!list_empty(&fd->prio_queue[i])) {
			rq = list_first_entry(&fd->prio_queue[i],
					      struct request, queuelist);
			list_del_init(&rq->queuelist);
			return rq;
		}

	/* 2. Select lane via starvation-bound + batch logic */
	lane = flow_select_lane(fd, khd);
	if (lane >= FLOW_NR_LANES)
		return NULL;

	/* 3. Pick the earliest-deadline request from the selected lane */
	rq = flow_first_rq(fd, lane);
	if (!rq)
		return NULL;

	/* 4. Remove from scheduler data structures atomically with lane
	 *    selection — the request now belongs to the blk-mq dispatch
	 *    path and will be submitted to the driver or requeued to
	 *    hctx->dispatch. */
	flow_remove_request(fd, rq, rq->q);

	/* 5. Update starvation counters */
	flow_update_starvation(fd, khd, lane);

	return rq;
}

static void flow_depth_updated(struct request_queue *q)
{
	blk_mq_set_min_shallow_depth(q, q->async_depth);
}

static void flow_limit_depth(blk_opf_t opf, struct blk_mq_alloc_data *data)
{
	/*
	 * Throttle async (non-sync-read) submissions to async_depth.
	 * This matches the approach used by mq-deadline and kyber.
	 */
	if (blk_mq_is_sync_read(opf))
		return;
	data->shallow_depth = data->q->async_depth;
}

static bool flow_allow_merge(struct request_queue *q, struct request *rq,
			     struct bio *bio)
{
	struct flow_rq_data *rd = get_rq_data(rq);
	u8 rq_lane, bio_lane;

	if (bio_data_dir(bio) != rq_data_dir(rq))
		return false;
	if (!rd)
		return true;
	rq_lane = READ_ONCE(rd->lane);
	if (bio->bi_opf & REQ_META || bio->bi_opf & REQ_PRIO)
		bio_lane = FLOW_LANE_READ;
	else if ((bio->bi_opf & REQ_SYNC) || bio->bi_iter.bi_size <= 4096)
		bio_lane = FLOW_LANE_READ;
	else
		bio_lane = FLOW_LANE_WRITE;
	return rq_lane == bio_lane;
}

/*
 * Lock-free work hint: checks simple pointer/list state without taking
 * fd->lock.  blk-mq tolerates false negatives (a brief delay before the
 * next dispatch cycle); false positives are harmless (dispatch_request
 * returns NULL, loop exits).
 */
static bool flow_has_work(struct blk_mq_hw_ctx *hctx)
{
	struct flow_data *fd = hctx->queue->elevator->elevator_data;

	return !list_empty_careful(&fd->prio_queue[0]) ||
	       !list_empty_careful(&fd->prio_queue[1]) ||
	       !RB_EMPTY_ROOT(&fd->read_root.rb_root) ||
	       !RB_EMPTY_ROOT(&fd->write_root.rb_root);
}

/* 6.18+ / 7.x init_sched: passes pre-allocated elevator_queue.
 * 6.12-6.17: apply 0002 compat patch. */
static int flow_init_sched(struct request_queue *q, struct elevator_queue *eq)
{
	struct flow_data *fd = eq->elevator_data;

	if (!fd)
		return -ENOMEM;
	fd->rq_data_cache = kmem_cache_create("flow_rq_data",
		sizeof(struct flow_rq_data), 0, SLAB_HWCACHE_ALIGN, NULL);
	if (!fd->rq_data_cache)
		goto free_fd;
	fd->rq_data_pool = mempool_create_slab_pool(q->nr_requests,
						     fd->rq_data_cache);
	if (!fd->rq_data_pool)
		goto drq_cache;
	fd->dl_group_cache = kmem_cache_create("flow_dl_group",
		sizeof(struct dl_group), 0, SLAB_HWCACHE_ALIGN, NULL);
	if (!fd->dl_group_cache)
		goto drq_pool;
	fd->dl_group_pool = mempool_create_slab_pool(q->nr_requests,
						      fd->dl_group_cache);
	if (!fd->dl_group_pool)
		goto ddl_cache;
	for (int i = 0; i < 2; i++)
		INIT_LIST_HEAD(&fd->prio_queue[i]);
	fd->read_root = RB_ROOT_CACHED;
	fd->write_root = RB_ROOT_CACHED;
	fd->merge_root = RB_ROOT_CACHED;
	fd->starvation_max[FLOW_LANE_READ] = FLOW_STARVATION_MAX_DEF_R;
	fd->starvation_max[FLOW_LANE_WRITE] = FLOW_STARVATION_MAX_DEF_W;
	fd->batch_max_read = FLOW_BATCH_MAX_READ_DEF;
	fd->batch_max_write = FLOW_BATCH_MAX_WRITE_DEF;
	fd->read_priority = 0;
	fd->is_rotational = !!(q->limits.features & BLK_FEAT_ROTATIONAL);
	spin_lock_init(&fd->lock);
	eq->elevator_data = fd;
	q->elevator = eq;
	blk_queue_flag_clear(QUEUE_FLAG_SQ_SCHED, q);

	/*
	 * Initialise async_depth so that flow_limit_depth() and
	 * flow_depth_updated() use a consistent value, matching the
	 * pattern of mq-deadline (nr_requests), kyber (75%), BFQ (75%).
	 */
	q->async_depth = q->nr_requests / FLOW_ASYNC_DEPTH_RATIO;
	flow_depth_updated(q);

	fd->queue = q;
	blk_stat_enable_accounting(q);
	return 0;
ddl_cache:
	kmem_cache_destroy(fd->dl_group_cache);
drq_pool:
	mempool_destroy(fd->rq_data_pool);
drq_cache:
	kmem_cache_destroy(fd->rq_data_cache);
free_fd:
	kfree(fd);
	return -ENOMEM;
}

static void flow_exit_sched(struct elevator_queue *e)
{
	struct flow_data *fd = e->elevator_data;

	WARN_ON_ONCE(!list_empty(&fd->prio_queue[0]));
	WARN_ON_ONCE(!list_empty(&fd->prio_queue[1]));
	{
		struct request *rq, *n;
		LIST_HEAD(drain);

		for (u8 lane = FLOW_LANE_READ; lane < FLOW_NR_LANES; lane++) {
			struct rb_root_cached *root = flow_root(fd, lane);
			struct rb_node *node;

			if (!root)
				continue;
			while ((node = rb_first_cached(root))) {
				struct dl_group *dlg = rb_entry(node,
					struct dl_group, node);
				struct flow_rq_data *rd;

				while ((rd = list_first_entry_or_null(
					&dlg->rqs, struct flow_rq_data,
					dl_node))) {
					list_del_init(&rd->dl_node);
					rq = rd->rq;
					list_add_tail(&rq->queuelist, &drain);
				}
				rb_erase_cached(&dlg->node, root);
				mempool_free(dlg, fd->dl_group_pool);
			}
		}
		list_for_each_entry_safe(rq, n, &drain, queuelist) {
			list_del_init(&rq->queuelist);
			if (rq->elv.priv[0]) {
				mempool_free(get_rq_data(rq), fd->rq_data_pool);
				rq->elv.priv[0] = NULL;
			}
		}
	}
	mempool_destroy(fd->dl_group_pool);
	mempool_destroy(fd->rq_data_pool);
	kmem_cache_destroy(fd->rq_data_cache);
	kmem_cache_destroy(fd->dl_group_cache);
	blk_stat_disable_accounting(fd->queue);
	kfree(fd);
}

static int flow_init_hctx(struct blk_mq_hw_ctx *hctx, unsigned int idx)
{
	struct flow_hctx_data *khd;

	khd = kzalloc_node(sizeof(*khd), GFP_KERNEL, hctx->numa_node);
	if (!khd)
		return -ENOMEM;
	khd->hctx = hctx;
	hctx->sched_data = khd;
	return 0;
}

static void flow_exit_hctx(struct blk_mq_hw_ctx *hctx, unsigned int idx)
{
	struct flow_hctx_data *khd = hctx->sched_data;

	if (!khd)
		return;
	kfree(khd);
	hctx->sched_data = NULL;
}

static ssize_t flow_version_show(struct elevator_queue *e, char *page)
{
	return sprintf(page, "%s\n", FLOW_VERSION);
}

static ssize_t flow_read_priority_show(struct elevator_queue *e, char *page)
{
	struct flow_data *fd = e->elevator_data;
	guard(spinlock_irqsave)(&fd->lock);
	return sprintf(page, "%d\n", fd->read_priority);
}

static ssize_t flow_read_priority_store(struct elevator_queue *e,
					const char *page, size_t count)
{
	struct flow_data *fd = e->elevator_data;
	int prio;

	if (kstrtoint(page, 10, &prio) || prio < -20 || prio > 19)
		return -EINVAL;
	guard(spinlock_irqsave)(&fd->lock);
	fd->read_priority = prio;
	return count;
}

#define FLOW_U16_RW(name) \
static ssize_t flow_##name##_show(struct elevator_queue *e, char *page) \
{ struct flow_data *fd = e->elevator_data; \
  guard(spinlock_irqsave)(&fd->lock); \
  return sprintf(page, "%u\n", fd->name); } \
static ssize_t flow_##name##_store(struct elevator_queue *e, \
	const char *p, size_t c) \
{ struct flow_data *fd = e->elevator_data; unsigned long v; \
  if (kstrtoul(p, 10, &v) || v > U16_MAX) return -EINVAL; \
  guard(spinlock_irqsave)(&fd->lock); fd->name = (u16)v; return c; }

FLOW_U16_RW(batch_max_read)
FLOW_U16_RW(batch_max_write)

#define FLOW_SV_ATTR_RW(suf, idx) \
static ssize_t flow_starvation_max_##suf##_show(struct elevator_queue *e, \
	char *page) \
{ struct flow_data *fd = e->elevator_data; \
  guard(spinlock_irqsave)(&fd->lock); \
  return sprintf(page, "%u\n", fd->starvation_max[idx]); } \
static ssize_t flow_starvation_max_##suf##_store(struct elevator_queue *e, \
	const char *p, size_t c) \
{ struct flow_data *fd = e->elevator_data; unsigned long v; \
  if (kstrtoul(p, 10, &v)) return -EINVAL; \
  guard(spinlock_irqsave)(&fd->lock); fd->starvation_max[idx] = (u32)v; \
  return c; }

FLOW_SV_ATTR_RW(read, FLOW_LANE_READ)
FLOW_SV_ATTR_RW(write, FLOW_LANE_WRITE)

#define ATTR_RW(n) __ATTR(n, 0644, flow_##n##_show, flow_##n##_store)
#define ATTR_RO(n) __ATTR(n, 0444, flow_##n##_show, NULL)

static struct elv_fs_entry flow_sched_attrs[] = {
	ATTR_RO(version),
	ATTR_RW(read_priority),
	ATTR_RW(batch_max_read),
	ATTR_RW(batch_max_write),
	ATTR_RW(starvation_max_read),
	ATTR_RW(starvation_max_write),
	__ATTR_NULL,
};

static void *flow_alloc_sched_data(struct request_queue *q)
{
	return kzalloc_node(sizeof(struct flow_data), GFP_KERNEL, q->node);
}

/*
 * All cleanup (mempool/slab teardown, kfree) is done in flow_exit_sched.
 * This empty free_sched_data prevents a double-free during elevator switch
 * when the core calls both exit_sched and free_sched_data on the old
 * elevator.  Cf. mq-deadline and BFQ which do not register free_sched_data
 * at all for the same reason.
 */
static void flow_free_sched_data(void *elv_data) { }

static struct elevator_type mq_flow = {
	.ops = {
		.depth_updated		= flow_depth_updated,
		.alloc_sched_data	= flow_alloc_sched_data,
		.free_sched_data	= flow_free_sched_data,
		.next_request		= flow_next_request,
		.former_request		= flow_former_request,
		.limit_depth		= flow_limit_depth,
		.allow_merge		= flow_allow_merge,
		.insert_requests	= flow_insert_requests,
		.prepare_request	= flow_prepare_request,
		.requeue_request	= flow_requeue_request,
		.dispatch_request	= flow_dispatch_request,
		.finish_request		= flow_finish_request,
		.has_work		= flow_has_work,
		.init_sched		= flow_init_sched,
		.exit_sched		= flow_exit_sched,
		.init_hctx		= flow_init_hctx,
		.exit_hctx		= flow_exit_hctx,
	},
	.elevator_attrs	= flow_sched_attrs,
	.elevator_name	= "flow-iosched",
	.elevator_owner	= THIS_MODULE,
	.icq_size	= 0,
	.icq_align	= 0,
};

MODULE_ALIAS("mq-flow-iosched");
static int __init flow_init(void)
{
	pr_info("Multi-Lane I/O Scheduler (FLOW) %s\n", FLOW_VERSION);
	return elv_register(&mq_flow);
}
static void __exit flow_exit(void) { elv_unregister(&mq_flow); }
module_init(flow_init);
module_exit(flow_exit);
MODULE_AUTHOR("flow-iosched contributors");
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Multi-Lane I/O Scheduler (FLOW)");
