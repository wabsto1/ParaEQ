## Summary


## Checklist
- [ ] `swift test` passes (CI runs it too)
- [ ] DSP changes include a unit test
- [ ] Engine changes verified live (`~/Library/Logs/ParaEQ.log` shows `callbacks=` increasing and healthy peaks, no restart loops)
- [ ] UI changes don't read 30 fps engine properties in a parent `body` (gotcha 9)
- [ ] Read the gotchas in `docs/ARCHITECTURE.md` if touching listeners, teardown, aggregates, or the IO callback
