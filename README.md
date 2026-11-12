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

events are validated when written, against the SQLite projection and before they are appended to the log; replay trusts the log and does not re-validate, so writes pay for the checks and reads stay fast.

===

## Libraries

By default, booru opens the managed library `default` under `$XDG_DATA_HOME/booru/libraries/`. If `XDG_DATA_HOME` is unset, it uses `~/.local/share/booru/libraries/`. Select another managed library with `-library:memes`; use an explicit path such as `-library:./memes` or `-library:/mnt/photos` to open a library elsewhere. A leading `~/` expands to `$HOME`.

## Frontend CSS

Tailwind 3.4.17 is a pinned build-only dependency. Run `task assets:css` to install locked npm dependencies and regenerate `static/tailwind.css` from the inline Tailwind directives, the Odin templates, and `static/gallery.js`. Build, run, and preview tasks do this automatically. Commit the generated stylesheet alongside class changes; serving prebuilt assets does not require Node. Load Tailwind before `static/gallery.css` so custom styles retain precedence.

## prior work

Pond https://github.com/raphaelsalaja/pond
TagStudio https://github.com/tagstudiodev/tagstudio
