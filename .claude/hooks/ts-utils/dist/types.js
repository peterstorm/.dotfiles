// src/types.ts
function* parseJsonl(content) {
  for (const line of content.split("\n")) {
    if (!line.trim())
      continue;
    try {
      yield JSON.parse(line);
    } catch {
    }
  }
}
function getContentBlocks(line) {
  const content = line.message?.content;
  if (!content)
    return [];
  if (typeof content === "string")
    return [];
  return content;
}
export {
  getContentBlocks,
  parseJsonl
};
