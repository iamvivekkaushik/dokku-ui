// Minimal ustar writer. `dokku certs:add <app>` reads a tarball containing
// server.crt and server.key from stdin when invoked over SSH.

function header(name: string, size: number): Buffer {
  const h = Buffer.alloc(512, 0);
  const field = (value: string, offset: number, length: number) => h.write(value, offset, length, 'ascii');
  const octal = (n: number, length: number) => n.toString(8).padStart(length - 1, '0') + '\0';
  field(name, 0, 100);
  field(octal(0o644, 8), 100, 8);
  field(octal(0, 8), 108, 8);
  field(octal(0, 8), 116, 8);
  field(octal(size, 12), 124, 12);
  field(octal(Math.floor(Date.now() / 1000), 12), 136, 12);
  field('        ', 148, 8);
  field('0', 156, 1);
  field('ustar\0', 257, 6);
  field('00', 263, 2);
  let sum = 0;
  for (const byte of h) sum += byte;
  field(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8);
  return h;
}

export function makeTar(files: Record<string, string>): Buffer {
  const parts: Buffer[] = [];
  for (const [name, content] of Object.entries(files)) {
    if (!/^[A-Za-z0-9._-]{1,99}$/.test(name)) throw new Error(`invalid tar entry name: ${name}`);
    const body = Buffer.from(content, 'utf8');
    parts.push(header(name, body.length), body, Buffer.alloc((512 - (body.length % 512)) % 512, 0));
  }
  parts.push(Buffer.alloc(1024, 0));
  return Buffer.concat(parts);
}
