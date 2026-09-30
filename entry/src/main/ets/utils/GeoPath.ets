/**
 * GeoPath —— GPS 路径插值纯函数（P2-8，对应上游 AdvancedPage GPS Tab 347-538 的数学部分）
 *
 * 职责（单一）：大圆距离（haversine）、初始方位角（bearing）、沿方位移动（球面目的地公式）。
 * 与页分离便于复核与测试：PeripheralPage 每秒 tick = 计算方向 → min(步长, 剩余) → 发 inject_data。
 * 单位约定：距离/步长 米；角度 度；spd 由页面换算为 m/s 后随 payload 下发。
 */

/** 地理点（WGS84 十进制度） */
export class GeoPoint {
  lat: number = 0;
  lon: number = 0;
}

const EARTH_R: number = 6371000;

function toRad(deg: number): number {
  return deg * Math.PI / 180;
}

function toDeg(rad: number): number {
  return rad * 180 / Math.PI;
}

/** 两点大圆距离（米，haversine） */
export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 2 * EARTH_R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** 从点1指向点2的初始方位角（度，正北=0，顺时针） */
export function bearingDeg(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const phi1 = toRad(lat1);
  const phi2 = toRad(lat2);
  const lambda = toRad(lon2 - lon1);
  const y = Math.sin(lambda) * Math.cos(phi2);
  const x = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(lambda);
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

/**
 * 球面目的地：从 (lat,lon) 沿方位 brgDeg 前进 distMeters。
 * （路径模式 1s tick：cur = dest(cur, bearing→终点, min(步长,剩余))）
 */
export function destinationPoint(lat: number, lon: number, brgDeg: number, distMeters: number): GeoPoint {
  const delta = distMeters / EARTH_R;
  const phi1 = toRad(lat);
  const lambda1 = toRad(lon);
  const theta = toRad(brgDeg);
  const phi2 = Math.asin(Math.sin(phi1) * Math.cos(delta) + Math.cos(phi1) * Math.sin(delta) * Math.cos(theta));
  const lambda2 = lambda1 + Math.atan2(
    Math.sin(theta) * Math.sin(delta) * Math.cos(phi1),
    Math.cos(delta) - Math.sin(phi1) * Math.sin(phi2));
  const out = new GeoPoint();
  out.lat = toDeg(phi2);
  out.lon = ((toDeg(lambda2) + 540) % 360) - 180; // 归一到 [-180,180)
  return out;
}
