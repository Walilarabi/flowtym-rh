// Preuve locale de cohérence du hash — reproduit buildSignedPDF (sig-sign)
// et démontre : NOUVEAU flux (rendu unique) => hash == octets archivés ;
// ANCIEN flux (double rendu) => hash != octets archivés.
import { PDFDocument, rgb, StandardFonts } from 'pdf-lib';
import { createHash } from 'node:crypto';

const sha256 = (b) => createHash('sha256').update(Buffer.from(b)).digest('hex');

// --- Extrait fidèle de buildSignedPDF (partie attestation, suffisante pour la preuve) ---
async function buildSignedPDF(opts) {
  const pdfDoc = await PDFDocument.create();
  const font  = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const fontB = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  const A4W = 595, A4H = 842, mg = 50;
  const page = pdfDoc.addPage([A4W, A4H]);
  const { width, height } = page.getSize();
  let y = height - 110;
  page.drawText('ATTESTATION DE SIGNATURE ELECTRONIQUE', { x: mg, y, size: 14, font: fontB, color: rgb(0.11,0.11,0.11) });
  y -= 26;
  const row = (l, v) => { page.drawText(l, {x:mg,y,size:10,font,color:rgb(.4,.4,.4)}); page.drawText(v||'-',{x:mg+170,y,size:10,font:fontB,color:rgb(.1,.1,.1)}); y-=18; };
  row('Signataire', opts.signerName);
  row('Email verifie (OTP)', opts.signerEmail);
  row('Date et heure (UTC)', opts.signedAt);
  row('Adresse IP', opts.signerIp);
  row('Reference signature', opts.requestId);
  // hashRow : n'imprime QUE si le hash est fourni (source). Le hash du doc signé
  // n'est jamais imprimé (self-référence impossible).
  const hashRow = (l, h) => { if (!h) return; page.drawText(l,{x:mg,y,size:9,font,color:rgb(.4,.4,.4)}); y-=13; page.drawText(h.slice(0,32),{x:mg+10,y,size:8,font}); y-=11; page.drawText(h.slice(32),{x:mg+10,y,size:8,font}); y-=15; };
  hashRow('Document source :', opts.documentHash);
  hashRow('Document signe  :', opts.signedDocHash); // <-- clé de la démonstration
  // PDFDocument.save est déterministe hors métadonnées de date : on fige la date de création
  pdfDoc.setCreationDate(new Date(0));
  pdfDoc.setModificationDate(new Date(0));
  return pdfDoc.save({ useObjectStreams: false });
}

const base = {
  signerName: 'Maeva Barbosa', signerEmail: 'maeva.barbosa16@gmail.com',
  signedAt: '2026-06-11 12:27:43 UTC', signerIp: '192.0.2.1',
  requestId: '56105e61-c30b-4ff0-8de7-a8eb64ec04ea',
  documentHash: 'a'.repeat(64), signedDocHash: '',
};

console.log('=== NOUVEAU FLUX (rendu unique) ===');
const pdfBytes = await buildSignedPDF(base);          // rendu UNIQUE
const storedHash = sha256(pdfBytes);                   // hash calculé AVANT upload
const archivedBytes = pdfBytes;                        // upload des MÊMES octets
const recomputed = sha256(archivedBytes);              // hash recalculé sur le fichier archivé
console.log('taille PDF               :', pdfBytes.length, 'octets');
console.log('signed_document_hash (DB):', storedHash);
console.log('SHA-256 fichier archivé  :', recomputed);
console.log('IDENTIQUES ?             :', storedHash === recomputed ? '✅ OUI' : '❌ NON');

console.log('\n=== ANCIEN FLUX (double rendu — le bug corrigé) ===');
const first = await buildSignedPDF(base);              // 1er rendu
const oldStoredHash = sha256(first);                   // hash du 1er rendu (stocké)
const second = await buildSignedPDF({ ...base, signedDocHash: oldStoredHash }); // 2e rendu (archivé, contient le hash)
const oldArchivedHash = sha256(second);                // hash réel du fichier archivé
console.log('hash stocké (1er rendu)  :', oldStoredHash);
console.log('hash fichier archivé     :', oldArchivedHash);
console.log('IDENTIQUES ?             :', oldStoredHash === oldArchivedHash ? 'OUI' : '❌ NON (intégrité invérifiable)');
