const servers = [
  {name:'api-prod-01', ip:'10.24.8.12', status:'Healthy', region:'US East', cpu:38, memory:62, uptime:'99.99%'},
  {name:'api-prod-03', ip:'10.24.8.14', status:'Degraded', region:'US East', cpu:71, memory:92, uptime:'99.91%'},
  {name:'web-prod-04', ip:'10.32.4.21', status:'Healthy', region:'EU West', cpu:46, memory:58, uptime:'99.98%'},
  {name:'worker-prod-02', ip:'10.48.2.17', status:'Healthy', region:'Asia Pacific', cpu:29, memory:54, uptime:'99.99%'},
  {name:'db-primary-01', ip:'10.24.16.5', status:'Healthy', region:'US East', cpu:52, memory:77, uptime:'100.0%'}
];

const rows = document.querySelector('#serverRows');
function renderServers(query='') {
  const filtered = servers.filter(s => `${s.name} ${s.ip} ${s.region} ${s.status}`.toLowerCase().includes(query.toLowerCase()));
  rows.innerHTML = filtered.map(s => `<tr><td><div class="server-name"><span class="server-glyph">▣</span><span>${s.name}<small style="display:block;color:#929aaa;font-weight:400;margin-top:3px">${s.ip}</small></span></div></td><td><span class="status-pill ${s.status === 'Degraded' ? 'degraded' : ''}">${s.status}</span></td><td>${s.region}</td><td><span class="usage"><span class="mini-progress"><i style="width:${s.cpu}%"></i></span>${s.cpu}%</span></td><td><span class="usage"><span class="mini-progress"><i style="width:${s.memory}%;background:${s.memory > 85 ? '#dc3e4b' : '#7657dc'}"></i></span>${s.memory}%</span></td><td>${s.uptime}</td><td><button class="row-more" aria-label="Actions for ${s.name}">•••</button></td></tr>`).join('');
  document.querySelector('#serverCount').textContent = `Showing ${filtered.length} of 24 servers`;
}
renderServers();
document.querySelector('#serverSearch').addEventListener('input', e => renderServers(e.target.value));

const sidebar = document.querySelector('#sidebar');
document.querySelector('#openNav').addEventListener('click', () => sidebar.classList.add('open'));
document.querySelector('#closeNav').addEventListener('click', () => sidebar.classList.remove('open'));
document.querySelectorAll('.nav a').forEach(link => link.addEventListener('click', () => {
  document.querySelectorAll('.nav a').forEach(a => a.classList.remove('active'));
  link.classList.add('active'); sidebar.classList.remove('open');
}));

const modal = document.querySelector('#deployModal');
const setModal = open => { modal.hidden = !open; document.body.style.overflow = open ? 'hidden' : ''; };
document.querySelector('#deployButton').addEventListener('click', () => setModal(true));
document.querySelector('#closeModal').addEventListener('click', () => setModal(false));
document.querySelector('#cancelModal').addEventListener('click', () => setModal(false));
modal.addEventListener('click', e => { if (e.target === modal) setModal(false); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') setModal(false); if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); document.querySelector('#globalSearch').focus(); } });

const toast = document.querySelector('#toast');
function showToast(message) { toast.textContent = message; toast.classList.add('show'); clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove('show'), 2600); }
document.querySelector('#deployForm').addEventListener('submit', e => { e.preventDefault(); setModal(false); showToast('Deployment queued successfully'); e.target.reset(); });
document.querySelector('#refreshButton').addEventListener('click', e => { e.currentTarget.firstChild.textContent = '↻ '; e.currentTarget.style.pointerEvents='none'; setTimeout(() => { e.currentTarget.style.pointerEvents=''; showToast('Metrics updated just now'); }, 650); });

const chartData = {
  cpu: {label:'CPU usage', value:'42.8%', path:'M0 162 C70 150,95 92,160 118 S255 94,320 123 S412 142,475 89 S550 70,620 99 S720 128,800 80'},
  memory: {label:'Memory usage', value:'68.2%', path:'M0 124 C80 112,110 140,180 118 S270 95,340 102 S430 76,500 92 S590 82,650 70 S735 65,800 58'},
  network: {label:'Network I/O', value:'1.4 Gb/s', path:'M0 180 C50 170,85 174,135 150 S205 80,270 142 S360 165,420 122 S495 40,550 110 S650 150,700 112 S760 93,800 105'}
};
document.querySelector('#chartTabs').addEventListener('click', e => {
  if (!e.target.dataset.series) return;
  document.querySelectorAll('#chartTabs button').forEach(b => b.classList.remove('active')); e.target.classList.add('active');
  const d = chartData[e.target.dataset.series]; document.querySelector('#legendLabel').textContent=d.label; document.querySelector('#chartCurrent').textContent=d.value;
  document.querySelector('#linePath').setAttribute('d', d.path); document.querySelector('#areaPath').setAttribute('d', `${d.path} L800 220 L0 220Z`);
});

document.querySelectorAll('.alert-item').forEach(item => item.addEventListener('click', () => showToast(`Opened alert: ${item.querySelector('strong').textContent}`)));
