import * as React from "react";

export interface SettingsGroupProps {
  /** Section header, shown in semibold secondary text with no border. */
  title: string;
  /** The rows (typically SettingsRow) in this borderless group. */
  children?: React.ReactNode;
}

/**
 * A titled, borderless run of related rows — the default grouping on a settings
 * page (a subheadline-semibold header over rows with no card chrome).
 */
export function SettingsGroup({ title, children }: SettingsGroupProps) {
  return (
    <div className="gk-group">
      <div className="gk-group__header">{title}</div>
      <div className="gk-group__body">{children}</div>
    </div>
  );
}
