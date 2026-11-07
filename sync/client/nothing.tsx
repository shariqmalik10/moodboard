/** Stands in for server-only modules and for parts of Next that have no meaning inside a card. */
export default function Nothing() {
  return null;
}
export const cookies = () => ({ get: () => undefined });
export const headers = () => new Map();
export const revalidatePath = () => {};
export const revalidateTag = () => {};
