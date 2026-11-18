/* Evaluated from the packaged game by JavaScriptBridge. Save text is data only.
 *
 * One IndexedDB object store holds the game's saves:
 *   "slot:main"                     the active save (fixed key, independent of the project name)
 *   "slot:main:before-import"       the save an import replaced (latest import only)
 *   "slot:main:protected:<rev>"     an unreadable or newer-version save that the player chose to set aside
 *   "/userfs/..."                   saves of the first web build, keyed by Godot's user data folder.
 *                                   They are read for migration and never written or deleted.
 * Every write is a compare-and-swap on "slot:main" inside one readwrite transaction, so a write from a
 * stale tab, an interrupted write or a failed write leaves the previous record exactly as it was.
 */
(globalThis.miningWorkshopSave = (() => {
  "use strict";
  const database = "mining-workshop-godot";
  const store = "saves";
  const slot = "slot:main";
  const lockName = "mining-workshop-godot:" + slot;
  // timeoutMs may be lowered by tests; the game uses the default.
  const state = { legacyKeys: [], lockHeld: false, lastDurability: null, hideHooks: false, timeoutMs: 10000 };

  function errorName(error) {
    return (error && typeof error.name === "string") ? error.name : "";
  }

  // Runs one transaction. finish(status, ...details) reports once; the timer aborts a transaction that
  // has not started committing, so a hung write never stays pending and never half-applies.
  function transact(mode, callback, operation) {
    let connection, transaction, settled = false;
    const finish = (...result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { connection?.close(); } catch { /* Already closed. */ }
      callback(...result);
    };
    const timer = setTimeout(() => {
      if (transaction) {
        // Committing already: let the real complete/abort event decide.
        try { transaction.abort(); } catch { return; }
      }
      finish("error", "timeout");
    }, state.timeoutMs);

    try {
      const request = indexedDB.open(database, 1);
      request.onblocked = () => finish("error", "blocked");
      request.onerror = () => finish("error", errorName(request.error) || "open");
      request.onupgradeneeded = () => {
        if (settled) request.transaction.abort();
        else request.result.createObjectStore(store);
      };
      request.onsuccess = () => {
        connection = request.result;
        if (settled) {
          connection.close();
          return;
        }
        try {
          transaction = connection.transaction(store, mode, { durability: "strict" });
          transaction.onabort = () => finish("error", errorName(transaction.error) || "aborted");
          operation(transaction, finish);
        } catch (error) {
          try { transaction?.abort(); } catch { /* Already inactive. */ }
          finish("error", errorName(error) || "transaction");
        }
      };
    } catch (error) {
      finish("error", errorName(error) || "indexeddb");
    }
  }

  function validRecord(record) {
    return !!record && typeof record.text === "string" && record.text.length > 0 &&
      typeof record.revision === "string" && record.revision.length > 0;
  }

  function rawText(record) {
    if (record === undefined) return "";
    if (record && typeof record.text === "string") return record.text;
    try { return JSON.stringify(record); } catch { return String(record); }
  }

  // What the browser says about the transaction's durability. "strict" is the only value that promises
  // the data reached storage before "complete"; anything else is reported as a basic guarantee.
  function durabilityOf(tx) {
    return typeof tx.durability === "string" ? tx.durability : "unsupported";
  }

  function parseList(value) {
    try {
      const list = typeof value === "string" ? JSON.parse(value) : value;
      return Array.isArray(list) ? list.filter(k => typeof k === "string" && k.length > 0) : [];
    } catch { return []; }
  }

  return {
    version: 2,
    slot,
    state,

    /* Load the active save.
     * callback(status, text, revision, source, detail)
     *   loaded   valid record in "slot:main"                         revision = its revision
     *   migrate  no "slot:main"; a valid record under a legacy key   revision = "" (the first commit creates the slot)
     *   invalid  "slot:main" (or the chosen legacy record) is not a save record; text = its raw content
     *   missing  nothing to load
     *   error    detail = timeout | blocked | <DOMException name>    the save was NOT read: never treat as empty
     */
    load(legacyKeysJson, callback) {
      const preferred = parseList(legacyKeysJson);
      state.legacyKeys = preferred;
      const answer = (status, ...rest) => {
        // Errors from opening the database carry their reason in the second slot.
        if (status === "error" && rest.length === 1) callback("error", "", "", "", rest[0]);
        else callback(status, ...rest);
      };
      transact("readonly", answer, (tx, finish) => {
        const records = tx.objectStore(store);
        const main = records.get(slot);
        const keys = records.getAllKeys();
        const legacy = {};
        keys.onsuccess = () => {
          const pathKeys = keys.result.filter(k => typeof k === "string" && k.startsWith("/"));
          // The current folder key first. Any other single folder key (an earlier project name) next.
          const others = pathKeys.filter(k => !preferred.includes(k));
          const candidates = preferred.filter(k => pathKeys.includes(k));
          if (candidates.length === 0 && others.length === 1) candidates.push(others[0]);
          for (const key of candidates) legacy[key] = records.get(key);
          legacy.ambiguous = candidates.length === 0 && others.length > 1;
        };
        tx.oncomplete = () => {
          const record = main.result;
          if (record !== undefined) {
            if (validRecord(record)) finish("loaded", record.text, record.revision, slot, "");
            else finish("invalid", rawText(record), typeof record?.revision === "string" ? record.revision : "", slot, "record");
            return;
          }
          for (const key of Object.keys(legacy)) {
            if (key === "ambiguous") continue;
            const old = legacy[key].result;
            if (old === undefined) continue;
            if (validRecord(old)) finish("migrate", old.text, "", key, "");
            else finish("invalid", rawText(old), "", key, "legacy-record");
            return;
          }
          finish("missing", "", "", "", legacy.ambiguous ? "ambiguous-legacy" : "");
        };
      });
    },

    /* Replace "slot:main" if it still holds expectedRevision ("" = no record yet).
     * options (JSON): backupKey  copy the replaced record there first (same transaction)
     *                 overwriteInvalid  allow replacing a record that is not a valid save (after export)
     *                 migratedFrom  remembered on the new record
     * callback(status, revision, durability, detail)
     *   saved     the transaction completed; durability is "strict" only when the browser promised it
     *   conflict  another tab (or an unexpected record) holds the slot; nothing was written
     *   quota     the browser refused the space; nothing was written
     *   error     detail says why; nothing was written
     */
    commit(expectedRevision, revision, text, optionsJson, callback) {
      let options = {};
      try { options = JSON.parse(optionsJson || "{}") || {}; } catch { options = {}; }
      const answer = (status, ...rest) => {
        if (status !== "error") { callback(status, ...rest); return; }
        const detail = (rest.length === 1 ? rest[0] : rest[2]) || "";
        callback(detail === "QuotaExceededError" ? "quota" : "error", "", "", detail);
      };
      transact("readwrite", answer, (tx, finish) => {
        const records = tx.objectStore(store);
        const request = records.get(slot);
        let rejected = false;
        let failure = "";
        tx.onabort = () => {
          const name = errorName(tx.error) || failure;
          if (rejected) finish("conflict", "", "", "revision");
          else if (name === "QuotaExceededError") finish("quota", "", "", name);
          else finish("error", "", "", name || "aborted");
        };
        request.onsuccess = () => {
          const current = request.result;
          let matches;
          if (current === undefined) matches = expectedRevision === "";
          else if (validRecord(current)) matches = current.revision === expectedRevision;
          else matches = options.overwriteInvalid === true &&
            (typeof current?.revision === "string" ? current.revision : "") === expectedRevision;
          if (!matches) {
            rejected = true;
            tx.abort();
            return;
          }
          try {
            if (current !== undefined && typeof options.backupKey === "string" && options.backupKey.startsWith(slot + ":")) {
              records.put({ ...(current && typeof current === "object" ? current : { raw: current }),
                backedUpAt: Date.now(), replacedBy: revision }, options.backupKey);
            }
            const record = { revision, text, savedAt: Date.now(), format: 1 };
            if (typeof options.migratedFrom === "string" && options.migratedFrom) record.migratedFrom = options.migratedFrom;
            records.put(record, slot);
          } catch (error) {
            failure = errorName(error) || "put";
            try { tx.abort(); } catch { /* Already inactive. */ }
          }
        };
        // A successful put can still be rolled back. Only "complete" confirms the new record replaced
        // the previous one.
        tx.oncomplete = () => {
          state.lastDurability = durabilityOf(tx);
          finish("saved", revision, state.lastDurability, "");
        };
      });
    },

    /* One tab writes at a time. callback("owned" | "busy" | "unsupported"). The lock is held until the
     * page goes away; waitMs lets a reloading page wait for its previous instance to let go. */
    claim(waitMs, callback) {
      if (state.lockHeld) { callback("owned"); return; }
      if (!globalThis.navigator?.locks?.request) { callback("unsupported"); return; }
      const wait = Math.max(0, Number(waitMs) || 0);
      const controller = wait > 0 && typeof AbortController === "function" ? new AbortController() : null;
      let answered = false, timer = null;
      const answer = (status) => {
        if (answered) return;
        answered = true;
        if (timer !== null) clearTimeout(timer);
        callback(status);
      };
      const granted = (lock) => {
        if (!lock || answered) {
          answer("busy");
          return undefined; // Not granted (or no longer wanted): release at once.
        }
        state.lockHeld = true;
        answer("owned");
        return new Promise(() => {}); // Held until the page unloads.
      };
      try {
        if (wait === 0 || !controller) {
          navigator.locks.request(lockName, { ifAvailable: true }, granted).catch(() => answer("busy"));
        } else {
          timer = setTimeout(() => { controller.abort(); answer("busy"); }, wait);
          navigator.locks.request(lockName, { signal: controller.signal }, granted).catch(() => answer("busy"));
        }
      } catch {
        answer("unsupported");
      }
    },

    /* callback() when the page is hidden or about to go away: the game starts a save at once. */
    onHide(callback) {
      if (state.hideHooks) return;
      state.hideHooks = true;
      document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") callback(); });
      addEventListener("pagehide", () => callback());
    },

    /* callback(persisted, requested): ask the browser not to evict this site's storage. */
    persist(request, callback) {
      const storage = globalThis.navigator?.storage;
      if (!storage?.persisted) { callback("unsupported", "unsupported"); return; }
      const ask = request && storage.persist ? storage.persist() : storage.persisted();
      ask.then(granted => callback(granted ? "yes" : "no", request ? "asked" : "checked"))
        .catch(() => callback("unknown", "error"));
    },
  };
})());
