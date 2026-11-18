// Test fixtures and readback only. Production commits come from the game.
function access(page, state) {
  return page.evaluate(replacement => new Promise((resolve, reject) => {
    const request = indexedDB.open('mining-workshop-godot', 1);
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      try {
        const txn = db.transaction('saves', replacement ? 'readwrite' : 'readonly');
        const cursor = txn.objectStore('saves').openCursor();
        let value;
        cursor.onsuccess = () => {
          const row = cursor.result;
          if (!row) return;
          value = { key: row.key, revision: row.value.revision, ...JSON.parse(row.value.text) };
          if (replacement) {
            if (location.hostname !== '127.0.0.1' || location.pathname !== '/__qa_fixture') {
              txn.abort();
              return;
            }
            row.update({ revision: value.revision + '-qa', text: JSON.stringify({ version: 1, state: replacement }) });
          }
        };
        txn.oncomplete = () => { db.close(); resolve(value); };
        txn.onabort = () => { db.close(); reject(txn.error || Error('Fixture transaction aborted')); };
      } catch (error) { db.close(); reject(error); }
    };
  }), state || null);
}

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
module.exports = { read: page => access(page), replace: access, legacy };
