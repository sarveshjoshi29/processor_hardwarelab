/**
 * Dual-Core RISC-V SoC - FPGA Development Suite
 * Frontend Application Controller
 */

let ws = null;

function el(id) {
  return document.getElementById(id);
}

function termAppend(text) {
  const term = el('term');
  term.textContent += text;
  term.scrollTop = term.scrollHeight;
}

function setStatus(s) {
  const statusEl = el('status');
  const indicator = el('statusIndicator');

  statusEl.textContent = s;

  // Update status indicator styling
  indicator.classList.remove('connected', 'connecting', 'error');

  if (s === 'connected') {
    indicator.classList.add('connected');
  } else if (s === 'connecting...' || s === 'opening serial...') {
    indicator.classList.add('connecting');
  } else if (s.includes('error')) {
    indicator.classList.add('error');
  }
}

async function refreshPorts() {
  try {
    const res = await fetch('/api/ports');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const sel = el('port');
    sel.innerHTML = '';
    for (const p of data.ports) {
      const opt = document.createElement('option');
      opt.value = p.device;
      opt.textContent = p.label;
      sel.appendChild(opt);
    }
    if (!data.ports || data.ports.length === 0) {
      setStatus('no COM ports found');
    }
  } catch (e) {
    setStatus('failed to load ports');
    console.error(e);
    termAppend('[ERROR] Failed to load COM ports. Is the FastAPI server running?\n');
  }
}

function wsConnect() {
  if (ws) return;

  const port = el('port').value;
  const baud = parseInt(el('baud').value, 10);

  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(
    `${scheme}://${location.host}/ws?port=${encodeURIComponent(port)}&baud=${baud}`
  );
  setStatus('connecting...');

  ws.onopen = () => setStatus('connected');
  ws.onclose = () => {
    ws = null;
    setStatus('disconnected');
  };
  ws.onerror = () => setStatus('error');

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'log') termAppend(msg.text);
    if (msg.type === 'uart') termAppend(msg.text);
    if (msg.type === 'status') setStatus(msg.text);
  };
}

function wsDisconnect() {
  if (ws) ws.close();
}

function wsDisconnectAsync() {
  return new Promise((resolve) => {
    if (!ws) return resolve();
    const old = ws;
    old.onclose = () => resolve();
    try {
      old.close();
    } catch {
      resolve();
    }
    setTimeout(() => resolve(), 500);
  });
}

async function programFPGA() {
  const port = el('port').value;
  const baud = parseInt(el('baud').value, 10);
  const imem = el('imem').files[0];
  const dmem = el('dmem').files[0];

  if (!imem || !dmem) {
    alert('Select both imem.hex and dmem.hex');
    return;
  }

  const fd = new FormData();
  fd.append('port', port);
  fd.append('baud', baud);
  fd.append('imem', imem);
  fd.append('dmem', dmem);

  const wasConnected = !!ws;
  if (ws) {
    termAppend('[WEB] Disconnecting monitor to program...\n');
    await wsDisconnectAsync();
  }

  termAppend(`\n[WEB] Programming ${port} @ ${baud}...\n`);

  const res = await fetch('/api/program', { method: 'POST', body: fd });
  const data = await res.json();
  if (!res.ok) {
    termAppend(`[WEB] ERROR: ${data.detail || 'program failed'}\n`);
    return;
  }
  termAppend(`[WEB] DONE: ${data.message}\n`);

  if (wasConnected) {
    termAppend('[WEB] Reconnecting monitor...\n');
    wsConnect();
  }
}

/**
 * Get the current code from CodeMirror 6 editor
 */
function getEditorCode() {
  // Wait for CodeMirror to be ready
  if (window.cmEditor) {
    return window.cmEditor.state.doc.toString();
  }
  // Fallback to textarea
  return el('c_code').value;
}

async function compileAndLoad() {
  const port = el('port').value;
  const baud = parseInt(el('baud').value, 10);

  // Get code from CodeMirror editor
  const cCode = getEditorCode();

  if (!cCode || cCode.trim() === '') {
    termAppend('[ERROR] Please enter some C code to compile.\n');
    return;
  }

  const fd = new FormData();
  fd.append('port', port);
  fd.append('baud', baud);
  fd.append('c_code', cCode);

  const wasConnected = !!ws;
  if (ws) {
    termAppend('[WEB] Disconnecting monitor to compile and program...\n');
    await wsDisconnectAsync();
  }

  termAppend(`\n[WEB] ▶ Compiling C code and programming ${port} @ ${baud}...\n`);

  // Trigger Extreme WOW visual reaction
  window.dispatchEvent(new Event('compileStarted'));

  const compileBtn = el('compileBtn');
  const originalHTML = compileBtn.innerHTML;

  // Show compiling state
  compileBtn.innerHTML = `
    <span class="spinner"></span>
    <span>Compiling...</span>
  `;
  compileBtn.disabled = true;
  compileBtn.classList.add('compiling');

  try {
    const res = await fetch('/api/compile_and_load', { method: 'POST', body: fd });
    const data = await res.json();

    if (data.compiler_output) {
      termAppend(`\n╭─────────────────────────────────────────╮\n`);
      termAppend(`│         COMPILER OUTPUT                 │\n`);
      termAppend(`╰─────────────────────────────────────────╯\n`);
      termAppend(`${data.compiler_output}\n`);
      termAppend(`───────────────────────────────────────────\n`);
    }

    if (!res.ok || !data.ok) {
      termAppend(`[ERROR] ${data.message || data.detail || 'Compilation failed.'}\n`);
      window.dispatchEvent(new Event('compileError'));
    } else {
      termAppend(`[SUCCESS] ✓ ${data.message}\n`);
      window.dispatchEvent(new Event('compileSuccess'));
    }
  } catch (err) {
    termAppend(`[ERROR] ${err.message}\n`);
    window.dispatchEvent(new Event('compileError'));
  } finally {
    compileBtn.innerHTML = originalHTML;
    compileBtn.disabled = false;
    compileBtn.classList.remove('compiling');
  }

  if (wasConnected) {
    termAppend('[WEB] Reconnecting monitor...\n');
    wsConnect();
  }
}

// Initialize application
window.addEventListener('DOMContentLoaded', async () => {
  el('refreshPorts').onclick = refreshPorts;
  el('connect').onclick = wsConnect;
  el('disconnect').onclick = wsDisconnect;
  el('program').onclick = programFPGA;
  el('compileBtn').onclick = compileAndLoad;

  // Add welcome message with a cool typewriter matrix effect
  const welcomeText = [
    '╔═══════════════════════════════════════════════════════════╗\n',
    '║     DUAL-CORE RISC-V SoC — FPGA DEVELOPMENT SUITE         ║\n',
    '║     CS224 Lab Project                                     ║\n',
    '╠═══════════════════════════════════════════════════════════╣\n',
    '║  → Select COM port and connect the UART monitor           ║\n',
    '║  → Write C code and click "Compile & Load"                ║\n',
    '║  → Set SW[15:14]=11, SW[0]=1, SW[2]=1 while programming   ║\n',
    '║  → Flip SW[2]=0 to execute your program                   ║\n',
    '╚═══════════════════════════════════════════════════════════╝\n\n'
  ].join('');

  async function typewriterEffect(text) {
    for (let i = 0; i < text.length; i++) {
        termAppend(text.charAt(i));
        // very fast typewriter
        await new Promise(r => setTimeout(r, 2));
    }
  }
  
  await typewriterEffect(welcomeText);

  // -----------------------------------------------------------------
  // COMMAND PALETTE (CMD+K)
  // -----------------------------------------------------------------
  const overlay = el('palette-overlay');
  const paletteInput = el('palette-input');
  const items = Array.from(document.querySelectorAll('.palette-item'));
  let activeIndex = 0;

  function togglePalette() {
    if (overlay.classList.contains('open')) {
      overlay.classList.remove('open');
      paletteInput.blur();
    } else {
      overlay.classList.add('open');
      paletteInput.value = '';
      items.forEach(i => i.style.display = 'flex');
      setActive(0);
      setTimeout(() => paletteInput.focus(), 50);
    }
  }

  function setActive(index) {
    items.forEach(i => i.classList.remove('active'));
    if (items[index]) {
      items[index].classList.add('active');
      items[index].scrollIntoView({ block: 'nearest' });
      activeIndex = index;
    }
  }

  document.addEventListener('keydown', (e) => {
    // CMD+K or CTRL+K
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      togglePalette();
    }
    
    if (!overlay.classList.contains('open')) return;

    if (e.key === 'Escape') {
      e.preventDefault();
      togglePalette();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      let next = activeIndex + 1;
      while (next < items.length && items[next].style.display === 'none') next++;
      if (next < items.length) setActive(next);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      let prev = activeIndex - 1;
      while (prev >= 0 && items[prev].style.display === 'none') prev--;
      if (prev >= 0) setActive(prev);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      executeAction(items[activeIndex].dataset.action);
      togglePalette();
    }
  });

  paletteInput.addEventListener('input', (e) => {
    const term = e.target.value.toLowerCase();
    let firstVisible = -1;
    items.forEach((item, index) => {
      const text = item.innerText.toLowerCase();
      if (text.includes(term)) {
        item.style.display = 'flex';
        if (firstVisible === -1) firstVisible = index;
      } else {
        item.style.display = 'none';
      }
    });
    if (firstVisible !== -1) setActive(firstVisible);
  });

  items.forEach((item, index) => {
    item.addEventListener('mouseenter', () => setActive(index));
    item.addEventListener('click', () => {
      executeAction(item.dataset.action);
      togglePalette();
    });
  });

  function executeAction(action) {
    if (action === 'compile') compileAndLoad();
    if (action === 'clear-term') el('term').textContent = '';
    if (action === 'connect') wsConnect();
    if (action === 'disconnect') wsDisconnect();
    if (action === 'overclock') {
        window.dispatchEvent(new Event('compileStarted'));
        setTimeout(() => window.dispatchEvent(new Event('compileSuccess')), 3000);
    }
  }

  await refreshPorts();
});
