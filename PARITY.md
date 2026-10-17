remaining frontend features to reach feature parity with
git:eissar/lfs-booru

## gallery_page
[ ] - hook up the Search button: submits `q` to `/gallery`, but the server ignores `q`
[ ] - hook up the "Suggest tags" button: requests `/genai/tags`, no route/handler exists
[ ] - hook up the page-size "2" option: server clamps limits below 10

## inspector
[ ] - hook up the 'regenerate thumbnail' (Refresh) button: `GET /regen-thumbnail` has no route/handler
[ ] - hook up the Delete button: `POST /delete` has no route/handler
for now, permanent delete. future possible
trash w/
[ ] - hook up the Save button (name and tags): `/update-metadata` has no route/handler

## item_card
none

## photo_grid
none

## toast
[ ] - hook up the Dismiss button: `toast.odin:27` uses `hx-on-click`, which htmx 2 ignores; use `hx-on:click`



