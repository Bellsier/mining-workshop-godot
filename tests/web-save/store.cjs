// Test fixtures and readback only. Production commits come from the game.
const SLOT = 'slot:main';

// Raw access to the game's store. Writes are only allowed from the isolated fixture page.
function raw(page, op, key, value) {
  return page.evaluate(({ op, key, value }) => new Promise((resolve, reject) => {
    if (op === 'put' && (location.hostname !== '127.0.0.1' || location.pathname !== '/__qa_fixture')) {
      reject(Error('Fixture writes require the isolated test page'));
      return;
    }
    const request = indexedDB.open('mining-workshop-godot', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('saves');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      try {
        const tx = db.transaction('saves', op === 'put' ? 'readwrite' : 'readonly');
        const store = tx.objectStore('saves');
        const req = op === 'put' ? store.put(value, key) : op === 'keys' ? store.getAllKeys() : store.get(key);
        tx.oncomplete = () => { db.close(); resolve(op === 'put' ? true : req.result); };
        tx.onabort = () => { db.close(); reject(tx.error || Error('Fixture transaction aborted')); };
      } catch (error) { db.close(); reject(error); }
    };
  }), { op, key, value: value === undefined ? null : value });
}

// The active save as { key, revision, version, state, migratedFrom } (undefined when there is none).
async function read(page) {
  const record = await raw(page, 'get', SLOT);
  if (!record) return undefined;
  return { key: SLOT, revision: record.revision, ...JSON.parse(record.text) };
}

// Replace the active save's state for a scenario (the game must not be running in this page).
async function replace(page, state) {
  const current = await raw(page, 'get', SLOT);
  const revision = (current?.revision || 'none') + '-qa';
  await raw(page, 'put', SLOT, { revision, text: JSON.stringify({ version: 1, state }) });
  return revision;
}

// The first web build's file in Godot's own IndexedDB mirror of user:// (read for migration only).
function legacy(page, key, write = null) {
  return page.evaluate(({ key, write }) => new Promise((resolve, reject) => {
    if (write && (location.hostname !== '127.0.0.1' || location.pathname !== '/__qa_fixture')) {
      reject(Error('Expected the isolated fixture page'));
      return;
    }
    const request = indexedDB.open('/userfs', 21);
    request.onupgradeneeded = () => request.result.createObjectStore('FILE_DATA').createIndex('timestamp', 'timestamp');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      const tx = db.transaction('FILE_DATA', write ? 'readwrite' : 'readonly');
      const files = tx.objectStore('FILE_DATA');
      const file = key + '/workshop_save.json';
      let read;
      if (write) {
        let directory = '';
        for (const part of key.split('/').filter(Boolean)) {
          directory += '/' + part;
          if (directory !== '/userfs') files.put({ mode: 16895, timestamp: new Date() }, directory);
        }
        files.put({ mode: 33206, timestamp: new Date(), contents: new TextEncoder().encode(JSON.stringify(write)) }, file);
      } else {
        read = files.get(file);
      }
      tx.oncomplete = () => {
        db.close();
        resolve(read?.result ? JSON.parse(new TextDecoder().decode(read.result.contents)) : undefined);
      };
      tx.onabort = () => { db.close(); reject(tx.error); };
    };
  }), { key, write });
}

module.exports = { SLOT, raw, read, replace, legacy };
