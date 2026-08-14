import sharp from "sharp";
import { createHash } from "node:crypto";

/**
 * Second line of defence — the client already resizes. Server re-normalises so
 * a rogue client cannot inflate our token bill.
 */
export async function normaliseImage(input: Buffer): Promise<Buffer> {
  return sharp(input, { failOn: "none" })
    .rotate()
    .resize(512, 512, { fit: "inside", withoutEnlargement: true })
    .jpeg({ quality: 70, mozjpeg: true })
    .toBuffer();
}

/** 64-bit average hash — identical/near-identical re-scans skip the model entirely. */
export async function pHash(jpeg: Buffer): Promise<string> {
  const { data } = await sharp(jpeg).greyscale().resize(8, 8, { fit: "fill" }).raw().toBuffer({ resolveWithObject: true });
  const mean = data.reduce((a, b) => a + b, 0) / data.length;
  let bits = "";
  for (const px of data) bits += px >= mean ? "1" : "0";
  return BigInt("0b" + bits).toString(16).padStart(16, "0");
}

export function sha256(b: Buffer): string {
  return createHash("sha256").update(b).digest("hex");
}
