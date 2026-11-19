// Which cortex a run used: the commit, and `-dirty` when the checkout had local changes.

export const cortexCommit = async (root: string): Promise<string> => {
  const run = async (args: readonly string[]): Promise<string> => {
    const proc = Bun.spawn(['git', '-C', root, ...args], { stdout: 'pipe', stderr: 'ignore' });
    const out = await new Response(proc.stdout).text();
    return (await proc.exited) === 0 ? out.trim() : '';
  };
  const head = await run(['rev-parse', '--short=12', 'HEAD']);
  if (head === '') return 'unknown';
  const dirty = (await run(['status', '--porcelain', '--', 'engine/src'])) !== '';
  return dirty ? `${head}-dirty` : head;
};
