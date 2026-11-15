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

handlers validate mutations against the SQLite projection before appending, `encode_event` / `ev_append` validates event encoding and per-op field rules before writing to the shard, and replay also validates parsed records (versions, field types, tags, and lifecycle transitions) when applying them.

===

## Libraries

By default, booru opens the managed library `default` under `$XDG_DATA_HOME/booru/libraries/`. If `XDG_DATA_HOME` is unset, it uses `~/.local/share/booru/libraries/`. Select another managed library with `-library:memes`; use an explicit path such as `-library:./memes` or `-library:/mnt/photos` to open a library elsewhere. A leading `~/` expands to `$HOME`.

## Frontend CSS

Tailwind 3.4.17 is a build-only dependency (standalone `tailwindcss` CLI). Run `task tailwind` to regenerate `static/tailwind.css` from the inline Tailwind directives, the Odin templates, and `static/gallery.js`. Build, run, and preview tasks do this automatically. Commit the generated stylesheet alongside class changes; serving prebuilt assets does not require Node or Tailwind. Load Tailwind before `static/gallery.css` so custom styles retain precedence.

## prior work

Pond https://github.com/raphaelsalaja/pond
TagStudio https://github.com/tagstudiodev/tagstudio

so now that we have a better idea of how different media types will work - in the server and in the markup - we have a more concrete understanding of the problem.
formats aside from img have (eventually user registerable) card media renderers . type video is the only implemented example of a card media renderer.
card media renderers are currently dynamic, but it's becoming apparent that cached/ derived state should live on disc. libraries are meant to
be user navigable. so the naming scheme for these should be straightforward. while user card media renderers is a usable internal name it's fairly opaque to a layperson.
should card media renderer derived state live in thumbnails/renderer/{oid}.webp ? something similar to that? exercise abstract thinking.
