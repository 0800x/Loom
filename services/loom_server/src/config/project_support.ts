import { readFileSync, statSync } from 'node:fs';
type Support={checkout:string;wallets:Array<{network:string;address:string}>};
export function projectSupport():Support {
 const source=process.env.LOOM_PROJECT_SUPPORT_FILE??new URL('./project_support.json',import.meta.url);
 if(statSync(source).size>65536)throw new Error('invalid_project_support');
 const value=JSON.parse(readFileSync(source,'utf8')) as Support;
 if(new URL(value.checkout).protocol!=='https:'||!Array.isArray(value.wallets)||value.wallets.length>4||value.wallets.some(w=>!['BNB Smart Chain (BEP-20)','Ethereum (ERC-20)'].includes(w.network)||!/^0x[0-9a-fA-F]{40}$/.test(w.address)))throw new Error('invalid_project_support');
 return value;
}
