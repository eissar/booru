booru is the Japanese word for 'board'

https://www.sakugabooru.com/

schema versioning. we do not version anything.
we have 'MAX_SUPPORTED_VERSION=0' to start.

database queries are based on the derived store.sqlite (or whatever the user wants)
so the library state/ doesn't need to know about the app at all.
if the app can't understand the database on startup, it just
discards it and rebuilds a new one.

the jsonl json lines currently have no 'version' key.
if we ever change event semantics, we will add a version key to the events.
during replay, if we come across a version greater than our supported version,
we panic on startup with 'upgrade'. libraries can be backwards but not forwards compatible.
