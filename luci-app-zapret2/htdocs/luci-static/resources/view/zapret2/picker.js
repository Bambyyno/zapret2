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
	var m = String(text || '').match(/^state=(\S+)/);
	if (m)
		state = m[1];
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
	return { state: state, summary: summary.trim(), opt: opt.trim(), log: log.trim() };
}

return view.extend({
	load: function() {
		return fs.exec(BIN, ['status']).then(function(res) {
			return (res && res.stdout) || '';
		}).catch(function() {
			return '';
		});
	},

	render: function(raw) {
		var parsed = splitStatus(raw);
		var stateNode = E('div', { 'id': 'zp-state' }, parsed.state);
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

		function refresh() {
			return fs.exec(BIN, ['status']).then(function(res) {
				var next = splitStatus((res && res.stdout) || '');
				stateNode.textContent = next.state;
				summaryNode.textContent = next.summary || 'Тест ещё не запускался.';
				optNode.textContent = next.opt;
				logNode.textContent = next.log;
			});
		}

		poll.add(refresh, 3);

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
					ui.addNotification(null, E('pre', {}, (res.stderr || res.stdout || 'не удалось запустить')), 'error');
				}
				return refresh();
			});
		}

		function apply() {
			return fs.exec(BIN, ['apply']).then(function(res) {
				var text = (res.stdout || '') + (res.stderr || '');
				if (res.code !== 0)
					ui.addNotification(null, E('pre', {}, text || 'нечего записывать'), 'error');
				else
					ui.addNotification(null, E('pre', {}, text), 'info');
				return refresh();
			});
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Zapret2'),
			E('div', { 'class': 'cbi-map-descr' },
				'Только домены YouTube: www.youtube.com, youtu.be, i.ytimg.com, googlevideo.com, youtubei.googleapis.com. ' +
				'Если домен уже открывается без обхода, поиск по нему не идёт. ' +
				'Семьи по очереди: fake и split/disorder, затем TTL и blob, в конце wssize и ipfrag. ' +
				'Первый успешный curl не заканчивает семью: держатся 2 или 3 прохода, победитель перепроверяется столько же раз. ' +
				'Из устойчивых строк берётся та, где меньше repeats и нет wssize. ' +
				'Один curl — не браузер. TLS и QUIC остаются разными профилями. ' +
				'Кнопка записи — единственное место, где меняются NFQWS2_OPT и NFQWS2_ENABLE.'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, 'Домены'),
						E('div', { 'class': 'cbi-value-field' },
							'www.youtube.com, youtu.be, i.ytimg.com, googlevideo.com, youtubei.googleapis.com')
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
