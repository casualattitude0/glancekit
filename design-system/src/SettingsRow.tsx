import * as React from "react";

export interface SettingsRowProps {
  /** The row's primary label. */
  title: string;
  /** Secondary caption dropped onto its own line below the title. */
  detail?: string;
  /** The control placed in the shared trailing column (switch, picker, button). */
  children?: React.ReactNode;
  /** Let the control fill the trailing column (segmented picker, slider) rather
   * than shrink to the trailing edge (switch, button). */
  fillControl?: boolean;
}

/**
 * One settings row: a label (plus optional detail caption) on the left and a
 * control in the shared fixed-width trailing column on the right — the
 * alignment that keeps switches, pickers and buttons on one edge down a page.
 */
export function SettingsRow({ title, detail, children, fillControl }: SettingsRowProps) {
  return (
    <div className="gk-row">
      <div className="gk-row__line">
        <span className="gk-row__title">{title}</span>
        <span className={"gk-row__control" + (fillControl ? " gk-row__control--fill" : "")}>
          {children}
        </span>
      </div>
      {detail && <div className="gk-row__detail">{detail}</div>}
    </div>
  );
}
