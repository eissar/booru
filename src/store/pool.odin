package store

import "../vendor/sqlite"
import "core:fmt"
import "core:strings"
import "core:sync"

RO_POOL_SIZE :: 5

ReadOnly_Pool :: struct {
	conns:  [RO_POOL_SIZE]^sqlite.DB,
	in_use: [RO_POOL_SIZE]bool,
	mu:     sync.Mutex,
	avail:  sync.Cond,
}

ro_pool_init :: proc(p: ^ReadOnly_Pool, library_path: string) {
	path, _ := strings.clone_to_cstring(
		fmt.tprintf("%s/store.sqlite", library_path),
		context.temp_allocator,
	)
	for i in 0 ..< RO_POOL_SIZE {
		db, rc := sqlite.open(path, readonly = true)
		if rc != sqlite.OK {
			ro_pool_destroy(p)
			fmt.panicf("readonly sqlite pool: open conn %d failed rc=%v", i, rc)
		}
		if rc = sqlite.exec(db, "PRAGMA busy_timeout = 5000", nil, nil, nil); rc != sqlite.OK {
			sqlite.close(db)
			ro_pool_destroy(p)
			fmt.panicf("readonly sqlite pool: set busy_timeout %d failed rc=%v", i, rc)
		}
		p.conns[i] = db
	}
}

ro_pool_destroy :: proc(p: ^ReadOnly_Pool) {
	for &db, i in p.conns {
		if db != nil {
			sqlite.close(db)
			db = nil
		}
		p.in_use[i] = false
	}
}

ro_pool_acquire :: proc(p: ^ReadOnly_Pool) -> (db: ^sqlite.DB, idx: int) {
	sync.guard(&p.mu)
	for {
		for used, i in p.in_use {
			if !used {
				p.in_use[i] = true
				return p.conns[i], i
			}
		}
		sync.cond_wait(&p.avail, &p.mu)
	}
}

ro_pool_release :: proc(p: ^ReadOnly_Pool, idx: int) {
	sync.guard(&p.mu)
	p.in_use[idx] = false
	sync.cond_signal(&p.avail)
}
