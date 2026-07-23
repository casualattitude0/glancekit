import * as React from "react";

export interface SegmentedOption {
  label: string;
  value: string;
}

export interface SegmentedControlProps {
  /** The segments. Strings are treated as both label and value. */
  options: Array<SegmentedOption | string>;
  /** The currently selected segment's value. */
  value?: string;
  /** Called with the selected segment's value. */
  onChange?: (value: string) => void;
}

/**
 * A macOS segmented control — a row of mutually exclusive options with the
 * selected segment raised onto a control-coloured chip. Use for 2–4 short
 * choices (a picker style); prefer a menu beyond that.
 */
export function SegmentedControl({ options, value, onChange }: SegmentedControlProps) {
  const norm = options.map((o) =>
    typeof o === "string" ? { label: o, value: o } : o
  );
  return (
    <div className="gk-segmented" role="tablist">
      {norm.map((o) => (
        <button
          key={o.value}
          type="button"
          role="tab"
          className="gk-segmented__seg"
          aria-selected={value === o.value}
          onClick={() => onChange?.(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
