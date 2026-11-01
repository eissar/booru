booru is the Japanese word for 'board'

https://www.sakugabooru.com/

Event sourcing and replay notes: `events.md`.

===

## Frontend CSS

Tailwind 3.4.17 is a pinned build-only dependency. Run `task assets:css` to install locked npm dependencies and regenerate `static/tailwind.css` from `assets/tailwind.css`, the Odin templates, and `static/gallery.js`. Build, run, and preview tasks do this automatically. Commit the generated stylesheet alongside class changes; serving prebuilt assets does not require Node. Load Tailwind before `static/gallery.css` so custom styles retain precedence.

## prior work

TagStudio is a project to learn from.
but tags=relationships
is an incredibly difficult problem,
and their application doesn't work performantly on libraries at
scale. The main guy (according to him) had very little programming
experience (ORM footgun). so the project's success
and continuous maintenance is an impressive feat.

we will circumvent database migrations and query complexity explosion.
simple flat tags and incremental indexes constrain query complexity


attempt python with an ORM really held them back.

dynamic ontologies probably require some kind of
specific domain understanding to



