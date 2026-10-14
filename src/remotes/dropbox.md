The Dropbox API is built for syncing an account, not for browsing it on demand. Every directory listing (files/list_folder) costs at least about 200 ms, even for an empty folder, and a folder has to be listed
before its subfolders are known. Opening a folder in a file explorer therefore always has a noticeable delay, and walking a tree takes time proportional to how many folders it has, not how many files. The
listing call can't filter by prefix, glob or exclusion. The only choices are one folder (recursive: false) or its entire subtree (recursive: true), and Dropbox's own documentation warns that the recursive mode
can cause performance problems or errors on large trees. Pages hold at most about 2000 entries and have to be fetched one after another, because each page needs the cursor from the previous one. search_v2
doesn't replace listing. It requires a query, returns ranked matches from an index that can lag behind recent changes, returns at most 1000 results per page, and doesn't guarantee a complete listing.

Folder metadata has no size, modified time or hash. A folder can't tell you whether anything inside it changed, and a subtree's size or file count can only be found by listing all of it. Only files carry
content_hash, rev and modified times. The supported way to detect changes is a cursor. One full listing produces a cursor, and later calls to list_folder/continue return only what changed since then. You can
be told when to make that call by list_folder/longpoll or by webhooks, which only notify and carry no details. Cursors have no documented lifetime and can be invalidated at any time with a reset error, which
forces a full re-list. Deleted entries don't say whether the path was a file or a folder, and a move shows up as a delete plus an add.

Throughput is capped by rate limits that Dropbox doesn't publish. Requests that exceed them get a 429 with Retry-After, and identical listing requests made at the same time can be rejected. Parallel requests
for different folders hide the per-request delay but run into those same limits. Media access costs a request too. get_thumbnail_batch returns at most 25 thumbnails per call, only for supported image formats
under a size cap, so a large grid of thumbnails becomes many requests. Full-resolution files need either a download through the API or a temporary link (get_temporary_link) that expires after four hours, so
links can't be stored permanently. Together, these push an explorer-style integration toward keeping its own index: a full listing once to build it, then cursor-driven updates. Live listing should be saved for
folders the index doesn't cover yet.

```bash
time rclone lsf dropbox-appfiles: --recursive --files-only \
   --exclude '.git/**' \
   --exclude '.hg/**' \
   --exclude '.svn/**' \
   --exclude 'node_modules/**' \
   --exclude '__pycache__/**' \
   --exclude '.venv/**' \
   --exclude 'venv/**' \
   --exclude '.cache/**' \
   --exclude '.DS_Store' \
   --exclude '._*' \
   --exclude 'Thumbs.db' \
   --exclude 'desktop.ini'

# real    0m24.016s
# user    0m1.655s
# sys     0m0.346s
```bash
time rclone lsf dropbox-appfiles: --recursive --files-only \
     --ignore-case \
     --filter '- .git/**' \
     --filter '- .hg/**' \
     --filter '- .svn/**' \
     --filter '- node_modules/**' \
     --filter '- __pycache__/**' \
     --filter '- .venv/**' \
     --filter '- venv/**' \
     --filter '- .cache/**' \
     --filter '- .DS_Store' \
     --filter '- ._*' \
     --filter '- Thumbs.db' \
     --filter '- desktop.ini' \
     --filter '+ *.{jpg,jpeg,jpe,jfif,png,gif,webp,avif,heic,heif,jxl,bmp,tif,tiff,svg,ico}' \
     --filter '- *'
# real    0m24.085s
# user    0m1.743s
# sys     0m0.295s
```

since it's so slow, we can actually generate intelligent recommendations for
users pretty accurately via static analysis of the results.
e.g., x folders accounted for x of the time

the cursor based workflow is more than possible but will require
much tweaking. Ideally I should be able to just point it at a 2tb
dropbox and it just tanks it but obv not possible atp

we *could* mandate max recursion, e.g:
> folder depth cannot go beyond 3 levels on slow remote types.
point booru at a folder with less nesting depth (ideally
flat file folder) or...

