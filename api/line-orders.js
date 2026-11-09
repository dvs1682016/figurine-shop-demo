// V1.13：只使用 LINE 驗證回傳的 sub，不讀取客戶端自報的 user ID。
const LINE_CHANNEL_ID = '2012475448';
const SUPABASE_URL = 'https://jzzufhnjhczqoywfxtbq.supabase.co';
const LINE_ISSUER = 'https://access.line.me';
const ORDER_ERRORS = new Set(['INVALID_ORDER', 'STOCK_UNAVAILABLE', 'PRICE_CHANGED', 'REQUEST_CONFLICT']);

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Figurine-Version', '1.13');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ message: 'METHOD_NOT_ALLOWED' });
  }

  const token = (req.headers.authorization || '').match(/^Bearer ([\w.-]{1,8192})$/)?.[1];
  if (!token) return res.status(401).json({ message: 'LINE_LOGIN_REQUIRED' });

  const { action, order, report } = req.body || {};
  if (!['list', 'bank', 'report'].includes(action) && (action !== 'place' || !order || typeof order !== 'object' || Array.isArray(order))) {
    return res.status(400).json({ message: 'INVALID_ORDER' });
  }

  if (action === 'report' && (!report ||
      typeof report.id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(report.id) ||
      typeof report.last5 !== 'string' || !/^[0-9]{5}$/.test(report.last5) ||
      typeof report.at !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(report.at))) {
    return res.status(400).json({ message: 'INVALID_REMITTANCE' });
  }

  const key = process.env.SUPABASE_SECRET_KEY;
  if (!key?.startsWith('sb_secret_')) return res.status(503).json({ message: 'SERVER_NOT_CONFIGURED' });

  try {
    const verified = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      body: new URLSearchParams({ id_token: token, client_id: LINE_CHANNEL_ID }),
      signal: AbortSignal.timeout(5000)
    });
    if (verified.status >= 500 || verified.status === 429) {
      return res.status(503).json({ message: 'LINE_UNAVAILABLE' });
    }
    if (!verified.ok) return res.status(401).json({ message: 'LINE_LOGIN_REQUIRED' });
    const identity = await verified.json();
    if (identity.iss !== LINE_ISSUER || identity.aud !== LINE_CHANNEL_ID ||
        !Number.isFinite(identity.exp) || identity.exp <= Date.now() / 1000 ||
        typeof identity.sub !== 'string' || !/^U[0-9a-f]{32}$/.test(identity.sub)) {
      return res.status(401).json({ message: 'LINE_LOGIN_REQUIRED' });
    }

    const placing = action === 'place';
    const routes = {
      place: ['place_line_figurine_order', { p_line_user_id: identity.sub, p_order: order }],
      list: ['list_line_figurine_orders', { p_line_user_id: identity.sub }],
      bank: ['figurine_bank_for_checkout', {}],
      report: ['report_figurine_remittance', {
        p_line_user_id: identity.sub, p_order_id: report?.id,
        p_last5: report?.last5, p_transferred_at: report?.at
      }]
    };
    const [functionName, args] = routes[action];
    const db = await fetch(SUPABASE_URL + '/rest/v1/rpc/' + functionName, {
      method: 'POST',
      headers: { apikey: key, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(7000)
    });
    const data = await db.json();
    if (!db.ok) {
      if (placing && ORDER_ERRORS.has(data.message)) return res.status(409).json({ message: data.message });
      if (action === 'report' && ['INVALID_REMITTANCE', 'ORDER_NOT_PAYABLE', 'ALREADY_REPORTED',
        'BANK_NOT_CONFIGURED'].includes(data.message)) return res.status(409).json({ message: data.message });
      return res.status(502).json({ message: 'DATABASE_UNAVAILABLE' });
    }
    if (placing && (data?.line_linked !== true || typeof order.p_request_id !== 'string' ||
        data.order_id !== order.p_request_id || !Number.isSafeInteger(data.total_ntd))) {
      return res.status(502).json({ message: 'LINE_BINDING_UNCONFIRMED' });
    }
    return res.status(200).json(data);
  } catch {
    return res.status(503).json({ message: 'TEMPORARILY_UNAVAILABLE' });
  }
};
