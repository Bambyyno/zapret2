'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var BIN = '/opt/zapret2/zapret2-picker.sh';

function field(id, label, value) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			E('input', {
				'class': 'cbi-input-text',
				'id': id,
				'type': 'text',
				'value': value,
				'style': 'width: 24em'
			})
		])
	]);
}

function choice(id, label, options) {
	var nodes = [];
	var i;
	for (i = 0; i < options.length; i++)
		nodes.push(E('option', { 'value': options[i], 'selected': options[i] === '3' ? '' : null }, options[i]));
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			E('select', { 'class': 'cbi-input-select', 'id': id }, nodes)
		])
	]);
}

function flag(id, label, on) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			E('input', { 'id': id, 'type': 'checkbox', 'checked': on ? '' : null })
		])
	]);
}

function bit(id) {
	return document.getElementById(id).checked ? '1' : '0';
}

function splitStatus(text) {
	var summary = '';
	var opt = '';
	var log = '';
	var state = 'idle';
	var service = 'stopped';
	var m = String(text || '').match(/^state=(\S+)/);
	if (m)
		state = m[1];
	var s = String(text || '').match(/^service=(\S+)/m);
	if (s)
		service = s[1];
	var parts = String(text || '').split(/^--- (\w+) ---$/m);
	var i;
	for (i = 1; i < parts.length; i += 2) {
		if (parts[i] === 'summary')
			summary = parts[i + 1] || '';
		else if (parts[i] === 'opt')
			opt = parts[i + 1] || '';
		else if (parts[i] === 'log')
			log = parts[i + 1] || '';
	}
	return { state: state, service: service, summary: summary.trim(), opt: opt.trim(), log: log.trim() };
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec(BIN, ['status']).then(function(res) {
				return (res && res.stdout) || '';
			}).catch(function(err) {
				return 'state=idle\n--- summary ---\n' + (err.message || err);
			}),
			fs.exec(BIN, ['show-opt']).then(function(res) {
				if (!res || res.code !== 0)
					return (res && (res.stderr || res.stdout)) || '';
				return res.stdout || '';
			}).catch(function() {
				return '';
			})
		]);
	},

	render: function(data) {
		var raw = data[0];
		var custom = data[1] || '';
		var parsed = splitStatus(raw);
		var stateNode = E('div', { 'id': 'zp-state' }, parsed.state);
		var serviceNode = E('div', { 'id': 'zp-service' }, parsed.service === 'running' ? 'включена' : 'выключена');
		var summaryNode = E('pre', {
			'id': 'zp-summary',
			'style': 'white-space:pre-wrap; max-height:16em; overflow:auto'
		}, parsed.summary || 'Тест ещё не запускался.');
		var optNode = E('pre', {
			'id': 'zp-opt',
			'style': 'white-space:pre-wrap; max-height:12em; overflow:auto'
		}, parsed.opt || '');
		var logNode = E('pre', {
			'id': 'zp-log',
			'style': 'white-space:pre-wrap; max-height:20em; overflow:auto'
		}, parsed.log || '');

		function showSummary(next) {
			if (next.summary)
				summaryNode.textContent = next.summary;
			else if (next.state === 'running')
				summaryNode.textContent = 'Тест идёт. NFQWS2_OPT не пишется, пока не нажата кнопка записи.';
			else if (!summaryNode.textContent)
				summaryNode.textContent = 'Тест ещё не запускался.';
		}

		function showError(err) {
			summaryNode.textContent = (err && err.message) ? err.message : String(err || 'не удалось выполнить команду');
		}

		function refresh() {
			return fs.exec(BIN, ['status']).then(function(res) {
				var next = splitStatus((res && res.stdout) || '');
				stateNode.textContent = next.state;
				serviceNode.textContent = next.service === 'running' ? 'включена' : 'выключена';
				showSummary(next);
				optNode.textContent = next.opt;
				logNode.textContent = next.log;
				logNode.scrollTop = logNode.scrollHeight;
			}).catch(showError);
		}

		poll.add(refresh, 1);

		function start() {
			var ipvs = document.getElementById('zp-ip').value.trim();
			var passes = document.getElementById('zp-passes').value.trim();
			return fs.exec(BIN, [
				'start-bg',
				'--ipvs', ipvs,
				'--tls12', bit('zp-tls12'),
				'--tls13', bit('zp-tls13'),
				'--quic', bit('zp-quic'),
				'--passes', passes
			]).then(function(res) {
				if (res.code !== 0) {
					summaryNode.textContent = res.stderr || res.stdout || 'не удалось запустить';
					ui.addNotification(null, E('pre', {}, summaryNode.textContent), 'error');
					return;
				}
				return refresh();
			}).catch(showError);
		}

		function serviceCmd(action) {
			return fs.exec(BIN, ['service', action]).then(function(res) {
				var msg = ((res.stdout || '') + (res.stderr || '')).trim();
				if (res.code !== 0) {
					summaryNode.textContent = msg || 'не удалось переключить службу';
					ui.addNotification(null, E('pre', {}, summaryNode.textContent), 'error');
					return;
				}
				ui.addNotification(null, E('pre', {}, msg), 'info');
				summaryNode.textContent = msg;
				return refresh();
			}).catch(showError);
		}

		function saveCustom() {
			var text = document.getElementById('zp-custom').value;
			return fs.exec(BIN, ['set-opt', text]).then(function(res) {
				var msg = ((res.stdout || '') + (res.stderr || '')).trim();
				if (res.code !== 0) {
					summaryNode.textContent = msg || 'не удалось записать стратегию';
					ui.addNotification(null, E('pre', {}, summaryNode.textContent), 'error');
					return;
				}
				ui.addNotification(null, E('pre', {}, msg), 'info');
				summaryNode.textContent = msg;
			}).catch(showError);
		}

		function apply() {
			return fs.exec(BIN, ['apply']).then(function(res) {
				var text = ((res.stdout || '') + (res.stderr || '')).trim();
				if (res.code !== 0) {
					summaryNode.textContent = text || 'нечего записывать';
					ui.addNotification(null, E('pre', {}, summaryNode.textContent), 'error');
					return;
				}
				ui.addNotification(null, E('pre', {}, text), 'info');
				summaryNode.textContent = text;
				return fs.exec(BIN, ['show-opt']).then(function(cur) {
					if (cur && cur.code === 0)
						document.getElementById('zp-custom').value = cur.stdout || '';
				});
			}).catch(showError);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Zapret2'),
			E('div', { 'class': 'cbi-map-descr' },
				'Домены YouTube. Страница (www.youtube.com и соседние имена) и видео (googlevideo.com) проверяются отдельно: успех страницы не считается успехом видео. ' +
				'Если домен уже открывается без обхода, поиск по нему не идёт. ' +
				'Семьи: fake и split, TTL и blob, fakedsplit и QUIC-blob, затем wssize. ' +
				'Если запомненная семья снова не проходит, следующая начинается со следующей семьи, без увеличения repeats. ' +
				'Журнал curl остаётся журналом. Запись ставит профиль Chrome, который дошёл до googlevideo: два hostfakesplit в одном circular, затем --new и UDP 443 с уже лежащим quic_initial_www_google_com.bin. ' +
				'Листы — суффиксы. youtube.com включает www и m, ytimg.com включает i.ytimg.com, ggpht.com включает yt3.ggpht.com, googlevideo.com включает rr*. ' +
				'Один curl — не браузер. Свою строку NFQWS2_OPT можно вставить ниже и записать отдельно.'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, 'Служба'),
						E('div', { 'class': 'cbi-value-field' }, [
							serviceNode,
							' ',
							E('button', {
								'class': 'cbi-button cbi-button-apply',
								'click': ui.createHandlerFn(this, serviceCmd, 'start')
							}, 'Включить'),
							' ',
							E('button', {
								'class': 'cbi-button cbi-button-remove',
								'click': ui.createHandlerFn(this, serviceCmd, 'stop')
							}, 'Выключить')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, 'Домены'),
						E('div', { 'class': 'cbi-value-field' },
							'youtube.com, youtu.be, youtubei.googleapis.com, googlevideo.com, ytimg.com, ggpht.com')
					]),
					field('zp-ip', 'IP (4, 6 или 46)', '4'),
					choice('zp-passes', 'Проходы и перепроверка', ['2', '3']),
					flag('zp-tls12', 'HTTPS TLS 1.2', true),
					flag('zp-tls13', 'HTTPS TLS 1.3', true),
					flag('zp-quic', 'QUIC', true),
					E('div', { 'class': 'cbi-value' }, [
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'class': 'cbi-button cbi-button-apply',
								'click': ui.createHandlerFn(this, start)
							}, 'Запустить тест'),
							' ',
							E('button', {
								'class': 'cbi-button cbi-button-save',
								'click': ui.createHandlerFn(this, apply)
							}, 'Записать сработавшую стратегию')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title', 'for': 'zp-custom' }, 'Своя стратегия'),
						E('div', { 'class': 'cbi-value-field' }, [
							E('textarea', {
								'id': 'zp-custom',
								'class': 'cbi-input-textarea',
								'style': 'width:100%; min-height:9em; font-family:monospace',
								'spellcheck': 'false'
							}, custom),
							E('div', { 'style': 'margin-top:0.5em' }, [
								E('button', {
									'class': 'cbi-button cbi-button-save',
									'click': ui.createHandlerFn(this, saveCustom)
								}, 'Записать свою стратегию')
							])
						])
					])
				])
			]),
			E('h3', {}, 'Состояние'),
			stateNode,
			E('h3', {}, 'Итог'),
			summaryNode,
			E('h3', {}, 'Строка NFQWS2_OPT'),
			optNode,
			E('h3', {}, 'Журнал'),
			logNode
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
