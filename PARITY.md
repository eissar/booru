remaining frontend features to reach feature parity with
git:eissar/lfs-booru

## gallery_page
[ ] - hook up the Search button: submits `q` to `/gallery`, but the server ignores `q`
[ ] - hook up the page-size "2" option: server clamps limits below 10

## inspector
[ ] - implement the 'regenerate thumbnail' (Refresh) handler: `GET /regen-thumbnail` is routed, but returns 501 Not Implemented

## item_card
none

## photo_grid
none

## toast
[ ] - hook up the Dismiss button: `toast.odin:27` uses `hx-on-click`, which htmx 2 ignores; use `hx-on:click`


[ ] - hook up the "Suggest tags" button: requests `/genai/tags`, no route/handler exists
