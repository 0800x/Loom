declare module 'qrcode' {
  const qr: { toString(text: string, options: { type: 'svg'; margin?: number; errorCorrectionLevel?: 'L' | 'M' | 'Q' | 'H' }): Promise<string> };
  export default qr;
}
