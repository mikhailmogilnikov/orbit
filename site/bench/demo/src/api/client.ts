// client
export interface Coordinates { latitude: number; longitude: number }
export async function fetch_client(at: Coordinates): Promise<string> {
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status}`);
  return response.text();
}
