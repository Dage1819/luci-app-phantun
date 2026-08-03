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

// Per-rule diagnostics (handshake status, resolved peer IP), keyed by rule
// name. Refreshed on the same 2s poll as everything else, but only for rules
// that are actually running (no point querying conntrack for a dead rule).
var connCache = {};
var resolvedCache = {};

var initState = 'unknown';
var curVersion = '';
var curRepo = '';
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

function getCurRepo() {
	return fs.exec(MANAGE, [ 'cur_repo' ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '').trim() || '';
	}).catch(function () { return ''; });
}

function getLog() {
	return fs.exec(MANAGE, [ 'log' ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '');
	}).catch(function () { return ''; });
}



// Live handshake status for one rule, from conntrack (not log parsing), so
// it always reflects the current moment. One of: established | handshaking
// | none.
function getRuleConn(name) {
	return fs.exec(MANAGE, [ 'rule_conn', name ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '').trim() || 'none';
	}).catch(function () { return 'none'; });
}

// Currently-resolved peer IP for a domain-based client rule (empty if the
// remote is a literal IP, or the rule has never started).
function getRuleResolved(name) {
	return fs.exec(MANAGE, [ 'rule_resolved', name ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '').trim();
	}).catch(function () { return ''; });
}

// Filtered, most-recent (up to 100) log lines for one rule: startup/error/
// timeout/close events only, per-attempt noise stripped out.
function getRuleLog(name) {
	return fs.exec(MANAGE, [ 'rule_log', name ]).then(function (res) {
		return ((res && res.stdout) ? res.stdout : '');
	}).catch(function () { return ''; });
}

// Show a read-only modal with one rule's filtered log (most recent 100
// lines that indicate an actual event, not per-connection churn).
function showRuleLogModal(name) {
	var logId = 'ph_rule_log_' + name;
	var pre = E('pre', {
		'id': logId,
		'style': 'max-height:400px;overflow:auto;background:#1e1e1e;color:#d4d4d4;' +
			'padding:12px;border-radius:6px;font-size:12px;line-height:1.5;white-space:pre-wrap;margin:0'
	}, '加载中…');

	ui.showModal('规则日志：' + name, [
		E('p', { 'style': 'color:#666;font-size:12px;margin-top:0' },
			'仅显示错误、超时、连接建立/关闭等有意义的事件（最近 100 条），已过滤掉正常的逐次重试噪音。'),
		pre,
		E('div', { 'class': 'right', 'style': 'margin-top:12px' }, [
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, '关闭')
		])
	]);

	getRuleLog(name).then(function (text) {
		var el = document.getElementById(logId);
		if (el) el.textContent = text || '（暂无相关日志）';
	});
}



function notifyInit() { initUpdaters.forEach(function (fn) { try { fn(); } catch (e) {} }); }
function notifyRows() { rowUpdaters.forEach(function (fn) { try { fn(); } catch (e) {} }); }

// All rule names known to the current form (populated once in render()), so
// refreshAll() knows which rules to query for handshake status / resolved IP
// without re-reading uci on every poll tick.
var allRuleNames = [];

function refreshAll() {
	return Promise.all([ getInitStatus(), getStatus(), getCurVersion(), getCurRepo() ]).then(function (r) {
		initState = r[0] || 'missing';
		statusCache = r[1] || {};
		curVersion = r[2] || 'none';
		curRepo = r[3] || '';
		notifyInit();
		notifyRows();

		// Second wave: per-rule diagnostics, only for rules currently running
		// (querying conntrack/resolved-IP for a stopped rule is meaningless).
		// Fired after the main state so the basic running/stopped label is
		// never blocked waiting on these extra shell calls.
		var running = allRuleNames.filter(isRunning);
		if (running.length) {
			Promise.all(running.map(function (name) {
				return Promise.all([ getRuleConn(name), getRuleResolved(name) ]).then(function (rr) {
					connCache[name] = rr[0];
					resolvedCache[name] = rr[1];
				});
			})).then(notifyRows);
		}
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

// Map init_status output to display properties.
function initInfo(state) {
	if (state === 'ready')        return { text: '已就绪', color: '#2e7d32', busy: false, ready: true };
	if (state === 'downloading')  return { text: '下载中…', color: '#ef6c00', busy: true };
	if (state === 'extracting')   return { text: '解压中…', color: '#ef6c00', busy: true };
	if (state && state.indexOf('error:') === 0) {
		var reason = state.slice(6);
		var map = {
			'download_failed':   '下载失败，请检查网络后重试',
			'extract_failed':    '解压失败',
			'binary_not_found':  '压缩包内未找到程序文件',
			'install_failed':    '安装失败',
			'no_version':        '无法获取最新版本',
			'unsupported_arch':  '不支持的系统架构'
		};
		return { text: '初始化失败', detail: map[reason] || reason, color: '#c62828', busy: false, error: true };
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
			'将 UDP 流量伪装成真实 TCP 连接（FakeTCP），穿透只允许 TCP 或对 UDP 限速/封锁的网络。性能高、开销小，常配合 WireGuard 使用。');

		// ================= 程序状态（版本 / 初始化 / 检测更新）=================
		s = m.section(form.TypedSection, '_status');
		s.anonymous = true;
		s.render = L.bind(function () {
			var self = this;
			var statusRowId = 'ph_status_row';
			var versionRowId = 'ph_version_row';

			var showInitLogModal = function (title) {
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
						var el = document.getElementById(logId);
						if (el) { el.textContent = r[0] || '正在启动…'; el.scrollTop = el.scrollHeight; }
						if (r[1] === 'ready') { finish(true); refreshAll(); }
						else if (r[1] && r[1].indexOf('error:') === 0) { finish(false); refreshAll(); }
					});
				};
				timer = setInterval(tick, 1000);
				tick();
			};

			var renderStatus = function () {
				var info = initInfo(initState);

				var el = document.getElementById(statusRowId);
				if (el) {
					var parts = [ E('span', { 'style': 'font-weight:600;color:' + info.color }, info.text) ];
					if (info.busy) parts.push(E('span', { 'class': 'spinning', 'style': 'margin-left:10px' }, ' '));
					if (info.error && info.detail)
						parts.push(E('span', { 'style': 'margin-left:10px;color:#c62828;font-size:12px' }, '（' + info.detail + '）'));
					el.innerHTML = '';
					parts.forEach(function (p) { el.appendChild(p); });
				}

				var vel = document.getElementById(versionRowId);
				if (vel) {
					var kids = [];
					var vtxt = (curVersion && curVersion !== 'none') ? curVersion : (info.ready ? '已安装' : '—');
					kids.push(E('span', { 'style': 'font-family:monospace;font-weight:600;margin-right:12px' }, vtxt));

					if (info.busy) {
						/* 处理中 */
					} else if (!info.ready) {
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(self, function () {
								return fs.exec(MANAGE, [ 'init' ]).then(function (res) {
									var out = ((res && res.stdout) ? res.stdout : '').trim();
									if ((res && res.code !== 0) || out.indexOf('error:') === 0) {
										ui.addNotification(null, E('p', {}, '初始化失败：' + (out || '未知错误')), 'error');
										return refreshAll();
									}
									initState = 'downloading'; notifyInit();
									showInitLogModal('初始化 Phantun');
									return refreshAll();
								}).catch(function (e) {
									ui.addNotification(null, E('p', {}, '初始化失败：' + (e.message || e)), 'error');
								});
							})
						}, info.error ? '重新初始化' : '初始化'));
					} else if (hasUpdate) {
						kids.push(E('span', { 'style': 'color:#ef6c00;margin-right:10px;font-size:12px' }, '发现新版 ' + latestVersion));
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(self, function () {
								return fs.exec(MANAGE, [ 'init' ]).then(function (res) {
									var out = ((res && res.stdout) ? res.stdout : '').trim();
									if ((res && res.code !== 0) || out.indexOf('error:') === 0) {
										ui.addNotification(null, E('p', {}, '更新失败：' + (out || '未知错误')), 'error');
										return refreshAll();
									}
									initState = 'downloading'; hasUpdate = false; notifyInit();
									showInitLogModal('更新 Phantun');
									return refreshAll();
								}).catch(function (e) {
									ui.addNotification(null, E('p', {}, '更新失败：' + (e.message || e)), 'error');
								});
							})
						}, '立即更新'));
					} else {
						kids.push(E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'disabled': checking ? 'disabled' : null,
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
											ui.addNotification(null, E('p', {}, '已是最新版本 ' + latestVersion), 'info');
									} else {
										ui.addNotification(null, E('p', {}, '检测更新失败，请稍后重试'), 'warning');
									}
									notifyInit();
								}).catch(function (e) {
									checking = false; notifyInit();
									ui.addNotification(null, E('p', {}, '检测更新失败：' + (e.message || e)), 'error');
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

			// Manual install note shown below status card
			var manualNote = E('div', { 'style': 'color:#666;font-size:12px;margin-top:4px;line-height:1.6' }, [
				'手动安装：通过 SSH 将对应架构的二进制文件上传至路由器，',
				E('br'),
				'重命名为 ',
				E('code', {}, '/usr/bin/phantun_client'),
				' 和 ',
				E('code', {}, '/usr/bin/phantun_server'),
				'，chmod +x 后重启服务。版本号将显示为"未知"。'
			]);

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '程序状态'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '核心状态'),
					E('div', { 'class': 'cbi-value-field', 'id': statusRowId }, E('em', {}, '加载中…'))
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '已安装版本'),
					E('div', { 'class': 'cbi-value-field', 'id': versionRowId }, E('em', {}, '…'))
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '核心来源'),
					E('div', { 'class': 'cbi-value-field', 'style': 'font-family:monospace' },
						curRepo ? 'https://github.com/' + curRepo : '…')
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '手动安装'),
					E('div', { 'class': 'cbi-value-field' }, manualNote)
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
			var name = uci.get('phantun', section_id, 'name') || section_id;
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
				var line1 = 'UDP %s:%s → %s:%s'.format(la, lp2, ra2, rp2);

				// If the remote is a domain, show the IP actually resolved and
				// in use (updated on the same poll cycle, from init.d's record
				// of what it passed to phantun -- not a fresh DNS lookup).
				var isDomain = ra2 && !/^[0-9.]+$/.test(ra2) && !/:/.test(ra2);
				if (!isDomain) return line1;

				var resId = 'res_' + section_id;
				var upd = function () {
					var el = document.getElementById(resId);
					if (!el) return;
					var ip = resolvedCache[name];
					el.textContent = ip ? ('当前解析：' + ip) : '当前解析：—';
				};
				rowUpdaters.push(upd);
				ensurePoll();
				requestAnimationFrame(upd);
				return E('div', {}, [
					E('div', {}, line1),
					E('div', { 'id': resId, 'style': 'font-size:12px;color:#666;margin-top:2px' }, '当前解析：—')
				]);
			}
		};

		o = s.option(form.DummyValue, '_status', '状态');
		o.modalonly = false;
		o.textvalue = function (section_id) {
			var name = uci.get('phantun', section_id, 'name') || section_id;
			if (allRuleNames.indexOf(name) === -1) allRuleNames.push(name);
			var stId = 'st_' + section_id;
			var connId = 'cn_' + section_id;
			var actId = 'act_' + section_id;

			var mkBtn = function (label, cls, action, disabled) {
				var attrs = { 'class': 'cbi-button cbi-button-' + cls, 'style': 'margin:0 2px' };
				if (disabled) attrs.disabled = 'disabled';
				else attrs.click = ui.createHandlerFn(this, function () { return runRuleAction(action, name); });
				return E('button', attrs, label);
			};

			// Handshake status line: only meaningful while the rule is running.
			// established = tunnel actually passing traffic; handshaking = TCP
			// SYN/SYN-ACK seen but not completed (stuck, e.g. reply not
			// arriving back); no entry yet -> conntrack has nothing for this
			// rule's port at all.
			var connInfo = function (running) {
				if (!running) return null;
				var c = connCache[name];
				if (c === 'established') return { text: '握手成功', color: '#2e7d32' };
				if (c === 'handshaking') return { text: '握手中…', color: '#ef6c00' };
				if (c === 'none') return { text: '未连接', color: '#999' };
				return null; // not fetched yet
			};

			var updater = function () {
				var stEl = document.getElementById(stId);
				var connEl = document.getElementById(connId);
				var actEl = document.getElementById(actId);
				if (!stEl && !connEl && !actEl) return;
				var t = transient[name];
				var running = isRunning(name);
				if (stEl) {
					if (t) stEl.innerHTML = '<span style="color:#ef6c00"><strong>' + t + '</strong></span>';
					else stEl.innerHTML = running
						? '<span style="color:#2e7d32"><strong>运行中</strong></span>'
						: '<span style="color:#999">已停止</span>';
				}
				if (connEl) {
					var ci = connInfo(running && !t);
					if (ci) {
						connEl.innerHTML = '';
						connEl.appendChild(E('span', { 'style': 'font-size:12px;color:' + ci.color }, ci.text));
						connEl.appendChild(E('a', {
							'href': '#', 'style': 'font-size:12px;margin-left:8px;color:#337ab7',
							'click': function (ev) { ev.preventDefault(); showRuleLogModal(name); }
						}, '查看日志'));
					} else {
						connEl.innerHTML = '';
					}
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
			return E('div', {}, [
				E('div', { 'id': stId }, '…'),
				E('div', { 'id': connId, 'style': 'margin-top:2px' })
			]);
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
			'该路由会写入系统「网络 → 静态路由」页面（IPv4/IPv6 分别显示为 phantun_规则名 开头的条目），可在那里查看是否生效、网关是什么。' +
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
			'可选。追加到 Phantun 命令行的额外参数（高级用途）。' +
			'其中 --time 用于开启 TCP 指纹伪装：握手包补全 MSS / SACK_PERMITTED / Timestamps 等选项，' +
			'并在后续数据包上携带滚动时间戳，使其更接近真实系统的 TCP 连接，避免因指纹过于精简（仅有 WScale）被部分网络环境的 DPI/防火墙识别并静默丢弃回包。' +
			'默认不开启，行为与官方版本完全一致。' +
			'必须服务端和客户端同时填写 --time 才会生效，只有一端填写会导致双方构造的数据包格式不一致，握手失败。');
		o.modalonly = true;

		return m.render();
	}
});
