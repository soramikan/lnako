export function suffix(path) {
  const index = path.lastIndexOf(".");
  return index < 0 ? "" : path.slice(index);
}
