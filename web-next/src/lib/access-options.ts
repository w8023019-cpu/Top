import {ApiError,gh,type Context} from './api';

// 1.1.28: akses publik (portmap / railway) aktif lagi di workflow SAMPAI di
// aplikasi Android. Fungsi ini dulu sengaja dijadikan stub no-op pada
// 2026-10-24, sehingga tes dan halaman settings tidak lagi melindungi
// endpoint yang belum diisi. Kembalikan validasinya.
export function portmapEndpointReady(inputs:Record<string,string>):boolean {
  const host=inputs.portmap_host??'';
  const port=inputs.portmap_port??'';
  if(!host||host.length>253||host.includes('://')||host.includes('/'))return false;
  if(!/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(host))return false;
  if(host.split('.').some(p=>!p||p.length>63||p.startsWith('-')||p.endsWith('-')))return false;
  if(!/^\d{1,5}$/.test(port))return false;
  const n=Number(port);
  return Number.isInteger(n)&&n>0&&n<=65535;
}

export async function requirePortmapConfiguration(c:Context,inputs:Record<string,string>){
  if(inputs.akses!=='portmap')return;
  if(!portmapEndpointReady(inputs))throw new ApiError(400,'Endpoint Portmap belum lengkap. Isi host dan port publik yang valid.');
  // Jangan pernah membiarkan akses publik tanpa .ovpn di secret.
  const secret=await gh<{name?:string}>(c,'/actions/secrets/PORTMAP_OVPN_CONFIG');
  if(!secret?.name)throw new ApiError(400,'Secret PORTMAP_OVPN_CONFIG belum terpasang. Tambahkan dulu di Settings → Secrets → Actions.');
}
