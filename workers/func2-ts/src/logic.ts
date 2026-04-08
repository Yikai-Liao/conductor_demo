export interface Func2Input {
  x: unknown;
}

export interface Func2Result {
  x: number;
  y: number;
}

export type YTag = "y_ge_10_5" | "y_lt_10_5";

export function computeFunc2(input: Func2Input): Func2Result {
  if (input.x === undefined || input.x === null || input.x === "") {
    throw new Error("x is required");
  }

  const numericX = Number(input.x);
  if (Number.isNaN(numericX)) {
    throw new Error("x must be numeric");
  }

  return {
    x: Number(numericX.toFixed(2)),
    y: Number((numericX * 2).toFixed(2)),
  };
}

export function buildYTag(y: number): YTag {
  return y >= 10.5 ? "y_ge_10_5" : "y_lt_10_5";
}
