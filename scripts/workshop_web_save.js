/* Evaluated from the packaged game by JavaScriptBridge. Save text is data only. */
(globalThis.miningWorkshopSave = (() => {
  "use strict";
  const database = "mining-workshop-godot";
  const store = "saves";
  const timeoutMs = 8000;

  function transact(mode, callback, operation) {
    let connection, transaction, settled = false;
    const finish = (status, text = "", revision = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      connection?.close();
      callback(status, text, revision);
    };
    const timer = setTimeout(() => {
      if (transaction) {
        // If it already finished, let the actual completion event decide.
        try { transaction.abort(); } catch { return; }
      }
      finish("error");
    }, timeoutMs);

    try {
      const request = indexedDB.open(database, 1);
      request.onblocked = request.onerror = () => finish("error");
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
          transaction.onabort = () => finish("error");
          // Some browsers silently ignore unsupported transaction options.
          if (mode === "readwrite" && transaction.durability !== "strict") {
            transaction.abort();
            return;
          }
          operation(transaction, finish);
        } catch {
          try { transaction?.abort(); } catch { /* Already inactive. */ }
          finish("error");
        }
      };
    } catch {
      finish("error");
    }
  }

  function validRecord(record) {
    return record && typeof record.text === "string" && record.text.length > 0 &&
      typeof record.revision === "string" && record.revision.length > 0;
  }

  return {
    load(key, callback) {
      transact("readonly", callback, (tx, finish) => {
        const request = tx.objectStore(store).get(key);
        tx.oncomplete = () => {
          const record = request.result;
          if (record === undefined) finish("missing");
          else if (validRecord(record)) finish("loaded", record.text, record.revision);
          else finish("error");
        };
      });
    },

    commit(key, expectedRevision, revision, text, callback) {
      transact("readwrite", callback, (tx, finish) => {
        const records = tx.objectStore(store);
        const request = records.get(key);
        let rejected = false;
        tx.onabort = () => finish(rejected ? "conflict" : "error");
        request.onsuccess = () => {
          const current = request.result;
          const matches = current === undefined ? expectedRevision === "" :
            validRecord(current) && current.revision === expectedRevision;
          if (!matches) {
            rejected = true;
            tx.abort();
            return;
          }
          try { records.put({ revision, text }, key); }
          catch { tx.abort(); }
        };
        // A successful put request can still be rolled back. Only this event
        // confirms that this snapshot replaced the previous durable record.
        tx.oncomplete = () => finish("saved", "", revision);
      });
    },
  };
})());
