import * as React from "react";

export type ButtonVariant = "primary" | "secondary" | "plain" | "destructive";
export type ButtonSize = "small" | "regular" | "large";

export interface ButtonProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "className"> {
  /** Visual role. `primary` is the accent-filled default action; `secondary`
   * is the bezeled neutral button; `plain` is borderless accent text;
   * `destructive` tints the label red for irreversible actions. */
  variant?: ButtonVariant;
  /** Control height, matching the macOS small/regular/large control sizes. */
  size?: ButtonSize;
  /** Button label / content. */
  children?: React.ReactNode;
}

/**
 * A push button in the macOS style — accent-filled primary, bezeled secondary,
 * borderless plain, and a red destructive variant. Use one primary per view.
 */
export function Button({
  variant = "secondary",
  size = "regular",
  children,
  disabled,
  ...rest
}: ButtonProps) {
  const cls = [
    "gk-btn",
    `gk-btn--${variant}`,
    size !== "regular" ? `gk-btn--${size}` : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <button className={cls} disabled={disabled} {...rest}>
      {children}
    </button>
  );
}
