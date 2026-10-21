# SQLite fixes

- [ ] The list and search queries have no pagination and materialize every match.
- [ ] Split database table creation and index creation into separate steps.
- [ ] Replace all `SELECT *` queries with explicit, bounded column projections.
- [ ] Avoid reading every image just to seed IDs; query `MAX(id)`.
- [ ] Eliminate the duplicate full-image read during missing-thumbnail generation.
- [ ] Batch mipmap OID lookups and select only the fields needed; the current path performs one full-image query per ID, including tags.
- [ ] Implement incremental replay using persisted cursors instead of rebuilding the store on every startup.
