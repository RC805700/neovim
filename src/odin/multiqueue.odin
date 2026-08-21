// multiqueue.odin — port of src/nvim/event/multiqueue.c
//
// Multi-level queue for selective async event processing. Pure data structure
// (QUEUE + heap allocation); no libuv dependency. Mirrors multiqueue.c
// exactly, including the parent/child link semantics.

package main

import "core:c"
import "base:runtime"

// Mirrors C's MultiQueueItem, whose `data` is a union of either a linked
// child-queue pointer (when `link` is true) or {event, parent_item}
// (when `link` is false). We store both possibilities as plain fields since
// this Odin build does not support `union` declarations.
MultiQueueItem :: struct {
	queue: rawptr,       // valid when link == true
	event: Event,        // valid when link == false
	parent_item: rawptr, // valid when link == false
	link: bool,
	node: Queue,
}

MulticastEvent :: struct {
	event: Event,
	fired: bool,
	refcount: c.int,
}

NILEVENT := Event{}

item_queue :: proc(it: ^MultiQueueItem) -> ^MultiQueue {
	return (^MultiQueue)(it.queue)
}

item_parent :: proc(it: ^MultiQueueItem) -> ^MultiQueueItem {
	return (^MultiQueueItem)(it.parent_item)
}

@(export)
multiqueue_new :: proc "c" (on_put: PutCallback, data: rawptr) -> ^MultiQueue {
	context = runtime.default_context()
	return _multiqueue_new(nil, on_put, data)
}

@(export)
multiqueue_new_child :: proc "c" (parent: ^MultiQueue) -> ^MultiQueue {
	context = runtime.default_context()
	assert(parent.parent == nil)
	parent.size += 1
	return _multiqueue_new(parent, nil, nil)
}

_multiqueue_new :: proc(parent: ^MultiQueue, on_put: PutCallback, data: rawptr) -> ^MultiQueue {
	rv := (^MultiQueue)(xmalloc(c.size_t(size_of(MultiQueue))))
	queue_init(&rv.headtail)
	rv.size = 0
	rv.parent = parent
	rv.on_put = on_put
	rv.data = data
	return rv
}

@(export)
multiqueue_free :: proc "c" (self: ^MultiQueue) {
	context = runtime.default_context()
	assert(self != nil)
	q := &self.headtail
	h := q
	cur := h.next
	for cur != h {
		next := cur.next
		item := queue_data(cur, MultiQueueItem, uintptr(offset_of(MultiQueueItem, node)))
		if self.parent != nil {
			queue_remove(&item_parent(item).node)
			xfree(item_parent(item))
		}
		queue_remove(cur)
		xfree(item)
		cur = next
	}
	xfree(self)
}

@(export)
multiqueue_get :: proc "c" (self: ^MultiQueue) -> Event {
	context = runtime.default_context()
	if multiqueue_empty(self) {
		return NILEVENT
	}
	return multiqueue_remove(self)
}

// Mirrors C's CREATE_EVENT macro: if the queue is NULL, invoke the event
// handler directly (synchronously) instead of enqueuing. This is how nvim
// handles watchers whose `events` queue was never set (e.g. server sockets).
create_event :: proc "c" (queue: ^MultiQueue, event: Event) {
	context = runtime.default_context()
	if queue != nil {
		multiqueue_put_event(queue, event)
	} else {
		argv := event.argv
		event.handler(&argv[0])
	}
}

@(export)
multiqueue_put_event :: proc "c" (self: ^MultiQueue, event: Event) {
	context = runtime.default_context()
	assert(self != nil)
	multiqueue_push(self, event)
	if self.parent != nil && self.parent.on_put != nil {
		self.parent.on_put(self.parent, self.parent.data)
	}
}

@(export)
multiqueue_move_events :: proc "c" (dest, src: ^MultiQueue) {
	context = runtime.default_context()
	for !multiqueue_empty(src) {
		event := multiqueue_get(src)
		multiqueue_put_event(dest, event)
	}
}

@(export)
	multiqueue_process_events :: proc "c" (self: ^MultiQueue) {
	context = runtime.default_context()
	assert(self != nil)
	for !multiqueue_empty(self) {
		event := multiqueue_remove(self)
		if event.handler != nil {
			event.handler(&event.argv[0])
		}
	}
}

@(export)
multiqueue_purge_events :: proc "c" (self: ^MultiQueue) {
	context = runtime.default_context()
	assert(self != nil)
	for !multiqueue_empty(self) {
		multiqueue_remove(self)
	}
}

@(export)
multiqueue_empty :: proc "c" (self: ^MultiQueue) -> bool {
	context = runtime.default_context()
	assert(self != nil)
	return queue_empty(&self.headtail)
}

@(export)
multiqueue_replace_parent :: proc "c" (self: ^MultiQueue, new_parent: ^MultiQueue) {
	context = runtime.default_context()
	assert(multiqueue_empty(self))
	self.parent = new_parent
}

@(export)
multiqueue_size :: proc "c" (self: ^MultiQueue) -> c.size_t {
	return self.size
}

multiqueueitem_get_event :: proc(item: ^MultiQueueItem, remove: bool) -> Event {
	assert(item != nil)
	ev: Event
	if item.link {
		linked := item_queue(item)
		assert(!multiqueue_empty(linked))
		child := queue_data(queue_head(&linked.headtail), MultiQueueItem,
			uintptr(offset_of(MultiQueueItem, node)))
		ev = child.event
		if remove {
			queue_remove(&child.node)
			xfree(child)
		}
	} else {
		if remove && item.parent_item != nil {
			queue_remove(&item_parent(item).node)
			xfree(item_parent(item))
			item.parent_item = nil
		}
		ev = item.event
	}
	return ev
}

multiqueue_remove :: proc(self: ^MultiQueue) -> Event {
	assert(!multiqueue_empty(self))
	h := queue_head(&self.headtail)
	queue_remove(h)
	item := queue_data(h, MultiQueueItem, uintptr(offset_of(MultiQueueItem, node)))
	assert(!(item.link && self.parent != nil))
	ev := multiqueueitem_get_event(item, true)
	self.size -= 1
	xfree(item)
	return ev
}

multiqueue_push :: proc(self: ^MultiQueue, event: Event) {
	item := (^MultiQueueItem)(xmalloc(c.size_t(size_of(MultiQueueItem))))
	item.link = false
	item.event = event
	item.parent_item = nil
	queue_insert_tail(&self.headtail, &item.node)
	if self.parent != nil {
		item.parent_item = xmalloc(c.size_t(size_of(MultiQueueItem)))
		p := item_parent(item)
		p.link = true
		p.queue = self
		queue_insert_tail(&self.parent.headtail, &p.node)
	}
	self.size += 1
}

@(export)
event_create_oneshot :: proc "c" (ev: Event, num: c.int) -> Event {
	context = runtime.default_context()
	data := (^MulticastEvent)(xmalloc(c.size_t(size_of(MulticastEvent))))
	data.event = ev
	data.fired = false
	data.refcount = num
	return event_create(multiqueue_oneshot_event, data)
}

multiqueue_oneshot_event :: proc(argv: ^rawptr) {
	data := (^MulticastEvent)(argv^)
	if !data.fired {
		data.fired = true
		if data.event.handler != nil {
			data.event.handler(&data.event.argv[0])
		}
	}
	data.refcount -= 1
	if data.refcount == 0 {
		xfree(data)
	}
}
