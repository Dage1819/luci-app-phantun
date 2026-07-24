'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';
'require fs';
'require ui';
'require network';

var MANAGE = '/usr/share/phantun/manage.sh';
var INIT = '/etc/init.d/phantun';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var statusCache = {};
var transient = {};
var rowUpdaters = [];
var pollStarted = false;

var initState = 'unknown';
var curVersion = '';
var latestVersion = '';
var hasUpdate = false;
var checking = false;
var initUpdaters = [];

function getStatus() {
	return L.resolveDefault(callServiceList('phantun'), {}).then(function (res) {
		var instances = {};
		try { instances = res['phantun']['instances'] || {}; } catch (e) { }
		return instances;
	});
}

function getInitStatus() {
	return fs.exec(MANAGE, [ 'init_status' ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '').trim() || 'missing';
	}).catch(function () { return 'missing'; });
}

function getCurVersion() {
	return fs.exec(MANAGE, [ 'cur_version' ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '').trim() || 'none';
	}).catch(function () { return 'none'; });
}

function getLog() {
	return fs.exec(MANAGE, [ 'log' ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '');
	}).catch(function () { return ''; });
}

// Show a modal that streams the init/update log in real time until the
// binary reaches a terminal state (ready / error). Warns not to close.
function showInitLogModal(title) {
	var logId = 'ph_init_log';
	var pre = E('pre', {
		'id': logId,
		'style': 'max-height:320px;overflow:auto;background:#1e1e1e;color:#d4d4d4;' +
			'padding:12px;border-radius:6px;font-size:12px;line-height:1.5;white-space:pre-wrap;margin:0'
	}, '正在启动…');

	var closeBtn = E('button', {
		'class': 'cbi-button cbi-button-neutral',
		'disabled': 'disabled',
		'click': ui.hideModal
	}, '请稍候…');

	ui.showModal(title || '初始化中', [
		E('p', { 'style': 'color:#c62828;font-weight:600' },
			'⚠ 正在下载并安装核心程序，请勿关闭本窗口或离开页面。'),
		pre,
		E('div', { 'class': 'right', 'style': 'margin-top:12px' }, [ closeBtn ])
	]);

	var timer = null;
	var finish = function (ok) {
		if (timer) { clearInterval(timer); timer = null; }
		closeBtn.removeAttribute('disabled');
		closeBtn.textContent = '关闭';
		closeBtn.className = 'cbi-button ' + (ok ? 'cbi-button-save' : 'cbi-button-reset');
	};

	var tick = function () {
		Promise.all([ getLog(), getInitStatus() ]).then(function (r) {
			var text = r[0] || '';
			var st = r[1] || '';
			var el = document.getElementById(logId);
			if (el) {
				el.textContent = text || '正在启动…';
				el.scrollTop = el.scrollHeight;
			}
			if (st === 'ready') { finish(true); }
			else if (st.indexOf('error:') === 0) { finish(false); }
		});
	};
	timer = setInterval(tick, 1000);
	tick();
}

function notifyInit() { initUpdaters.forEach(function (fn) { try { fn(); } catch (e) {} }); }
function notifyRows() { rowUpdaters.forEach(function (fn) { try { fn(); } catch (e) {} }); }

function refreshAll() {
	return Promise.all([ getInitStatus(), getStatus(), getCurVersion() ]).then(function (r) {
		initState = r[0] || 'missing';
		statusCache = r[1] || {};
		curVersion = r[2] || 'none';
		notifyInit();
		notifyRows();
		return true;
	});
}

function ensurePoll() {
	if (pollStarted) return;
	pollStarted = true;
	poll.add(refreshAll, 2);
}

function isRunning(name) {
	return !!(statusCache[name] && statusCache[name].running);
}

function ruleAction(action, name) {
	return fs.exec(INIT, [ action, name ]).then(function (res) {
		if (res && res.code !== 0)
			ui.addNotification(null, E('p', {}, '操作失败：%s'.format((res.stderr || res.stdout || '未知错误'))), 'error');
		return res;
	}).catch(function (e) {
		ui.addNotification(null, E('p', {}, '操作失败：%s'.format(e.message || e)), 'error');
	});
}

function runRuleAction(action, name) {
	transient[name] = (action === 'rule_stop') ? '停止中'
		: (action === 'rule_restart') ? '重启中' : '启动中';
	notifyRows();
	return ruleAction(action, name).then(function () {
		return new Promise(function (resolve) {
			setTimeout(function () {
				refreshAll().then(function () {
					delete transient[name];
					notifyRows();
					setTimeout(refreshAll, 1500);
					resolve();
				});
			}, 700);
		});
	});
}

function initInfo(state) {
	if (state === 'ready')            return { text: '已就绪', color: '#2e7d32', busy: false, ready: true };
	if (state === 'downloading')      return { text: '下载中…', color: '#ef6c00', busy: true };
	if (state === 'extracting')       return { text: '解压中…', color: '#ef6c00', busy: true };
	if (state === 'installing_unzip') return { text: '安装依赖中…', color: '#ef6c00', busy: true };
	if (state && state.indexOf('error:') === 0) {
		var reason = state.slice(6);
		var map = {
			'download_failed': '下载失败，请检查网络后重试',
			'extract_failed': '解压失败',
			'binary_not_found': '压缩包内未找到程序文件',
			'install_failed': '安装失败',
			'no_unzip': '缺少 unzip 且自动安装失败'
		};
		var msg = map[reason] || reason;
		if (reason.indexOf('unsupported_arch') === 0)
			msg = '不支持的架构：' + reason.split(':')[1];
		return { text: '初始化失败', detail: msg, color: '#c62828', busy: false, error: true };
	}
	return { text: '未初始化', color: '#757575', busy: false };
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('phantun'),
			network.getNetworks()
		]);
	},

	render: function (data) {
		var m, s, o;
		rowUpdaters = [];
		initUpdaters = [];

		var networks = (data && data[1]) || [];

		m = new form.Map('phantun', 'Phantun',
			'将 UDP 流量伪装成真实 TCP 连接（FakeTCP），穿透只允许 TCP 或对 UDP 限速/封锁的网络。性能高、开销小，常配合 WireGuard 使用。' +
			'首次使用请先「初始化」，自动下载适配本机架构的程序（不内置，适配任意内核）。');

		// ================= 程序状态（含版本 / 检测更新）=================
		s = m.section(form.TypedSection, '_status');
		s.anonymous = true;
		s.render = L.bind(function () {
			var self = this;
			var statusRowId = 'ph_status_row';
			var versionRowId = 'ph_version_row';

			var renderStatus = function () {
				var info = initInfo(initState);

				var el = document.getElementById(statusRowId);
				if (el) {
					var parts = [ E('span', { 'style': 'font-weight:600;color:%s'.format(info.color) }, info.text) ];
					if (info.busy)
						parts.push(E('span', { 'class': 'spinning', 'style': 'margin-left:10px' }, ' '));
					if (info.error && info.detail)
						parts.push(E('span', { 'style': 'margin-left:10px;color:#c62828;font-size:12px' }, '（' + info.detail + '）'));
					else if (!info.ready && !info.busy)
						parts.push(E('span', { 'style': 'margin-left:10px;color:#999;font-size:12px' }, '请先完成初始化'));
					el.innerHTML = '';
					parts.forEach(function (p) { el.appendChild(p); });
				}

				var vel = document.getElementById(versionRowId);
				if (vel) {
					var kids = [];
					var vtxt = (curVersion && curVersion !== 'none' && curVersion !== 'unknown') ? curVersion
						: (info.ready ? '已安装' : '—');
					kids.push(E('span', { 'style': 'font-family:monospace;font-weight:600;margin-right:12px' }, vtxt));

					if (info.busy) {
						/* 处理中，不显示按钮 */
					} else if (!info.ready) {
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(self, function () {
								return fs.exec(MANAGE, [ 'init' ]).then(function () {
									initState = 'downloading'; notifyInit();
									showInitLogModal('初始化 Phantun');
									return refreshAll();
								}).catch(function (e) {
									ui.addNotification(null, E('p', {}, '初始化失败：%s'.format(e.message || e)), 'error');
								});
							})
						}, info.error ? '重新初始化' : '初始化'));
					} else if (hasUpdate) {
						kids.push(E('span', { 'style': 'color:#ef6c00;margin-right:10px;font-size:12px' }, '发现新版 ' + latestVersion));
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(self, function () {
								return fs.exec(MANAGE, [ 'update' ]).then(function () {
									initState = 'downloading'; hasUpdate = false; notifyInit();
									showInitLogModal('更新 Phantun');
									return refreshAll();
								}).catch(function (e) {
									ui.addNotification(null, E('p', {}, '更新失败：%s'.format(e.message || e)), 'error');
								});
							})
						}, '立即更新'));
					} else {
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'click': ui.createHandlerFn(self, function () {
								checking = true; notifyInit();
								return fs.exec(MANAGE, [ 'check_update' ]).then(function (res) {
									checking = false;
									var out = ((res && res.stdout) ? res.stdout : '').trim();
									var p = out.split('|');
									if (p[0] === 'latest' && p[1]) {
										latestVersion = p[1];
										hasUpdate = (p[2] === '1');
										if (!hasUpdate)
											ui.addNotification(null, E('p', {}, '已是最新版本 %s'.format(latestVersion)), 'info');
									} else {
										ui.addNotification(null, E('p', {}, '检测更新失败，请稍后重试'), 'warning');
									}
									notifyInit();
								}).catch(function (e) {
									checking = false; notifyInit();
									ui.addNotification(null, E('p', {}, '检测更新失败：%s'.format(e.message || e)), 'error');
								});
							})
						}, checking ? '检测中…' : '检测更新'));
					}
					vel.innerHTML = '';
					kids.forEach(function (k) { vel.appendChild(k); });
				}
			};

			initUpdaters.push(renderStatus);
			ensurePoll();
			requestAnimationFrame(renderStatus);

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '程序状态'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '运行状态'),
					E('div', { 'class': 'cbi-value-field', 'id': statusRowId }, E('em', {}, '加载中…'))
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '核心版本'),
					E('div', { 'class': 'cbi-value-field', 'id': versionRowId }, E('em', {}, '…'))
				])
			]);
		}, s, this);

		// ================= 高级设置（DNS / 域名监控）=================
		s = m.section(form.NamedSection, 'global', 'global', '高级设置');
		s.addremove = false;

		o = s.option(form.Value, 'dns_server', 'DNS 服务器',
			'可选。用于解析对端域名的 DNS 服务器。留空使用系统默认。');
		o.placeholder = '1.1.1.1';
		o.datatype = 'ipaddr';

		o = s.option(form.Value, 'check_interval', '域名监控间隔（秒）',
			'启用域名监控的客户端规则，每隔此秒数重新解析一次，IP 变化时自动重启隧道。');
		o.datatype = 'uinteger';
		o.placeholder = '60';

		o = s.option(form.Flag, 'bypass_proxy', 'DNS 解析绕过代理',
			'强制发往上面「DNS 服务器」的查询走物理 WAN 出口，不经过任何代理（如 WireGuard）。' +
			'避免隧道断开后因解析走隧道而无法重连的死锁。除非有特殊分流需求，建议保持开启。');
		o.default = '1';

		o = s.option(form.ListValue, 'wan_iface', '外网接口',
			'「DNS 解析绕过代理」使用的物理外网接口。留空为自动检测（默认 wan 接口）。' +
			'若外网口改过名或有多 WAN，请手动指定。');
		o.value('', '自动（wan）');
		networks.forEach(function (net) {
			var name = net.getName();
			if (name === 'loopback' || name.charAt(0) === '@') return;
			o.value(name, name);
		});
		o.default = '';
		o.depends('bypass_proxy', '1');

		// ================= 规则列表 =================
		s = m.section(form.GridSection, 'rule', '隧道规则',
			'每条规则是一个独立的 Phantun 实例。服务端 = 有公网 IP 的一方；客户端 = NAT 后需连接服务端的一方。');
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = '添加规则';

		o = s.option(form.Flag, 'enabled', '启用');
		o.editable = true;

		o = s.option(form.Value, 'name', '名称');
		o.rmempty = false;
		o.placeholder = 'wg';

		o = s.option(form.ListValue, 'mode', '模式');
		o.value('server', '服务端');
		o.value('client', '客户端');
		o.default = 'client';

		o = s.option(form.DummyValue, '_target', '目标');
		o.modalonly = false;
		o.textvalue = function (section_id) {
			var mode = uci.get('phantun', section_id, 'mode') || 'client';
			if (mode === 'server') {
				var lp = uci.get('phantun', section_id, 'local_port') || '?';
				var ra = uci.get('phantun', section_id, 'remote_addr') || '127.0.0.1';
				var rp = uci.get('phantun', section_id, 'remote_port') || '?';
				return '监听 TCP :%s → UDP %s:%s'.format(lp, ra, rp);
			} else {
				var la = uci.get('phantun', section_id, 'local_addr') || '127.0.0.1';
				var lp2 = uci.get('phantun', section_id, 'local_port') || '?';
				var ra2 = uci.get('phantun', section_id, 'remote_addr') || '?';
				var rp2 = uci.get('phantun', section_id, 'remote_port') || '?';
				return 'UDP %s:%s → %s:%s'.format(la, lp2, ra2, rp2);
			}
		};

		o = s.option(form.DummyValue, '_status', '状态');
		o.modalonly = false;
		o.textvalue = function (section_id) {
			var name = uci.get('phantun', section_id, 'name') || section_id;
			var stId = 'st_' + section_id;
			var actId = 'act_' + section_id;

			var mkBtn = function (label, cls, action, disabled) {
				var attrs = { 'class': 'cbi-button cbi-button-' + cls, 'style': 'margin:0 2px' };
				if (disabled) attrs.disabled = 'disabled';
				else attrs.click = ui.createHandlerFn(this, function () { return runRuleAction(action, name); });
				return E('button', attrs, label);
			};

			var updater = function () {
				var stEl = document.getElementById(stId);
				var actEl = document.getElementById(actId);
				if (!stEl && !actEl) return;
				var t = transient[name];
				var running = isRunning(name);
				if (stEl) {
					if (t) stEl.innerHTML = '<span style="color:#ef6c00"><strong>' + t + '</strong></span>';
					else stEl.innerHTML = running
						? '<span style="color:#2e7d32"><strong>运行中</strong></span>'
						: '<span style="color:#999">已停止</span>';
				}
				if (actEl) {
					var busy = !!t;
					var btns = running
						? [ mkBtn('重启', 'action', 'rule_restart', busy), mkBtn('停止', 'negative', 'rule_stop', busy) ]
						: [ mkBtn('启动', 'positive', 'rule_start', busy), mkBtn('停止', 'neutral', 'rule_stop', true) ];
					actEl.innerHTML = '';
					btns.forEach(function (b) { actEl.appendChild(b); });
				}
			};
			rowUpdaters.push(updater);
			ensurePoll();
			requestAnimationFrame(updater);
			return E('span', { 'id': stId }, '…');
		};

		o = s.option(form.DummyValue, '_actions', '操作');
		o.modalonly = false;
		o.textvalue = function (section_id) {
			return E('div', { 'id': 'act_' + section_id, 'style': 'display:flex;justify-content:center;white-space:nowrap' }, '…');
		};

		o = s.option(form.Value, 'local_addr', '本地监听地址',
			'仅客户端。本地暴露 UDP 端点的地址，通常 127.0.0.1（供 WireGuard 等本地应用连接）。');
		o.placeholder = '127.0.0.1';
		o.depends('mode', 'client');
		o.modalonly = true;

		o = s.option(form.Value, 'local_port', '本地端口',
			'服务端：对外监听的 TCP 端口。客户端：本地 UDP 端口（本地应用连接此端口）。');
		o.datatype = 'port';
		o.modalonly = true;
		o.rmempty = false;

		o = s.option(form.Value, 'remote_addr', '对端地址',
			'服务端：转发目标 UDP 服务地址（通常 127.0.0.1）。客户端：Phantun 服务端 IP 或域名。');
		o.modalonly = true;
		o.rmempty = false;

		o = s.option(form.Value, 'remote_port', '对端端口',
			'服务端：目标 UDP 服务端口（如 WireGuard 端口）。客户端：Phantun 服务端 TCP 端口。');
		o.datatype = 'port';
		o.modalonly = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'family', '地址族',
			'仅客户端。解析对端域名时使用 IPv4（A 记录）还是 IPv6（AAAA 记录）。对端为 IP 时忽略。');
		o.value('ipv4', 'IPv4');
		o.value('ipv6', 'IPv6');
		o.default = 'ipv4';
		o.depends('mode', 'client');
		o.modalonly = true;

		o = s.option(form.Flag, 'monitor', '域名监控',
			'仅客户端。对端为域名时，定期重新解析，IP 变化时自动重启隧道（DDNS）。对端为固定 IP 时无需开启。');
		o.default = '0';
		o.depends('mode', 'client');
		o.modalonly = true;

		o = s.option(form.Flag, 'route_via_wan', '服务端例外路由',
			'仅客户端。当本机默认路由已整体指向某个隧道（如 WireGuard 全局代理）时，' +
			'去 Phantun 服务端的流量会被路由进该隧道，形成「隧道要靠自己才能建立」的死锁。' +
			'勾选后自动为服务端 IP 添加一条走物理 WAN 的明细路由（绕过隧道）。' +
			'仅在做全局代理时才需要勾选；普通场景请保持关闭。' +
			'对端为域名时会自动纳入监控：解析 IP 变化时同步更新该路由（无需另开「域名监控」）。');
		o.default = '0';
		o.depends('mode', 'client');
		o.modalonly = true;

		o = s.option(form.Flag, 'auto_fw', '自动防火墙',
			'仅服务端。勾选后自动把外网 TCP（本地端口）转发到 Phantun 并放行，无需手动配置防火墙。取消勾选并保存后会自动清除对应规则。默认同时覆盖 IPv4 与 IPv6。');
		o.default = '1';
		o.rmempty = false;
		o.depends('mode', 'server');
		o.modalonly = true;

		o = s.option(form.Value, 'tun_name', 'TUN 接口名',
			'可选。留空使用默认。多条规则请设不同接口名避免冲突。');
		o.modalonly = true;

		o = s.option(form.ListValue, 'log_level', '日志级别');
		o.value('error', 'error');
		o.value('warn', 'warn');
		o.value('info', 'info');
		o.value('debug', 'debug');
		o.default = 'info';
		o.modalonly = true;

		o = s.option(form.Value, 'extra_args', '额外参数',
			'可选。追加到 Phantun 命令行的额外参数（高级用途）。');
		o.modalonly = true;

		return m.render();
	}
});
