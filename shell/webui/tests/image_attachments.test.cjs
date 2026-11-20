const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const entry = path.resolve(__dirname, '../src/image_attachments.ts');
assert.ok(fs.existsSync(entry), 'E5.23: falta el validador de imágenes del compositor');
const { inspectImageBytes, readImageAttachment, MAX_IMAGE_BYTES } = require('../dist/image_attachments.test.cjs');
let checks = 0;
function check(name, fn) { fn(); checks++; console.log(`ok ${name}`); }
function png(w = 1, h = 1) {
  const b = new Uint8Array(33);
  b.set([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82]);
  const v = new DataView(b.buffer); v.setUint32(16,w); v.setUint32(20,h); b[24]=8; b[25]=6;
  return b;
}
check('PNG por firma y dimensiones', () => assert.deepEqual(inspectImageBytes(png(20,10)), { mime:'image/png', ext:'png', width:20, height:10 }));
check('texto renombrado PNG rechazado', () => assert.throws(() => inspectImageBytes(new TextEncoder().encode('esto no es PNG')), /PNG, JPEG o WebP/));
check('archivo vacío rechazado', () => assert.throws(() => inspectImageBytes(new Uint8Array()), /vacía/));
check('cota de bytes', () => assert.throws(() => inspectImageBytes(new Uint8Array(MAX_IMAGE_BYTES+1)), /5 MB/));
check('dimensiones y píxeles acotados', () => {
  for (const b of [png(0,1),png(8193,1),png(8192,8192)]) assert.throws(() => inspectImageBytes(b), /dimensiones/);
});
check('PNG truncado o sin IHDR rechazado', () => {
  assert.throws(() => inspectImageBytes(png().slice(0,24)), /PNG/);
  const b=png();b[12]=0;assert.throws(() => inspectImageBytes(b), /PNG/);
});
check('JPEG SOF con segmentos previos', () => {
  const b = new Uint8Array([255,216,255,224,0,4,0,0,255,192,0,11,8,0,10,0,20,1,1,17,0,255,217]);
  assert.deepEqual(inspectImageBytes(b), { mime:'image/jpeg',ext:'jpg',width:20,height:10 });
  assert.throws(() => inspectImageBytes(b.slice(0,17)), /JPEG/);
});
check('WebP VP8X, VP8 y VP8L', () => {
  const make=(chunk,body) => { const b=new Uint8Array(20+body.length); const v=new DataView(b.buffer); b.set(Buffer.from('RIFF'));v.setUint32(4,b.length-8,true);b.set(Buffer.from('WEBP'+chunk),8);v.setUint32(16,body.length,true);b.set(body,20); return b; };
  assert.equal(inspectImageBytes(make('VP8X',new Uint8Array([0,0,0,0,19,0,0,9,0,0]))).width,20);
  assert.equal(inspectImageBytes(make('VP8 ',new Uint8Array([0,0,0,157,1,42,20,0,10,0]))).height,10);
  const lossless = new Uint8Array(6);lossless[0]=47;new DataView(lossless.buffer).setUint32(1,19 | (9<<14),true);
  assert.equal(inspectImageBytes(make('VP8L',lossless)).height,10);
  const bad=make('VP8X',new Uint8Array(10));bad[4]=0;assert.throws(() => inspectImageBytes(bad), /WebP/);
});
(async () => {
  let closed=0;
  global.createImageBitmap=async () => ({width:20,height:10,close(){closed++;}});
  const blob = new Blob([png(20,10)]);blob.name='renombrada.dat';
  const result=await readImageAttachment(blob,0);
  assert.equal(result.name,'renombrada.dat');assert.equal(result.mime,'image/png');assert.equal(result.width,20);assert.equal(closed,1);
  assert.deepEqual(Buffer.from(result.data_base64,'base64'),Buffer.from(png(20,10)));checks++;console.log('ok lectura por bytes sin confiar en extensión o MIME');
  await assert.rejects(readImageAttachment(blob,4),/4 imágenes/);checks++;console.log('ok cota de cuatro');
  global.createImageBitmap=async () => {throw new Error('decode failed');};
  await assert.rejects(readImageAttachment(blob,0),/decodificar/);checks++;console.log('ok imagen no decodificable rechazada');
  global.createImageBitmap=async () => ({width:21,height:10,close(){closed++;}});
  await assert.rejects(readImageAttachment(blob,0),/dimensiones/);checks++;console.log('ok cabecera y bitmap deben coincidir');
  const unreadable={name:'broken.png',size:1,arrayBuffer:async()=>{throw new Error('denied');}};
  await assert.rejects(readImageAttachment(unreadable,0),/denied/);checks++;console.log('ok fallo de lectura propagado');
  console.log(`${checks} checks PASS`);
})().catch(e=>{console.error(e);process.exitCode=1;});
