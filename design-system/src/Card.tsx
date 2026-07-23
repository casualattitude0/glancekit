import * as React from "react";

export interface CardProps {
  /** Optional section header rendered above the card in secondary text. */
  title?: string;
  /** Rows or content. Direct children are separated by hairline dividers,
   * giving the grouped System-Settings card look. */
  children?: React.ReactNode;
  /** Suppress the dividers between children (for non-row content). */
  plain?: boolean;
}

/**
 * A titled, bordered card of rows — the System-Settings card surface
 * (`controlBackground` fill, hairline border, 8pt radius). Rows are separated
 * by hairline dividers automatically.
 */
export function Card({ title, children, plain }: CardProps) {
  const items = React.Children.toArray(children).filter((c) => c != null);
  return (
    <div className="gk-card">
      {title && <div className="gk-card__title">{title}</div>}
      <div className="gk-card__body">
        {items.map((child, i) => (
          <React.Fragment key={i}>
            {i > 0 && !plain && <div className="gk-card__divider" />}
            {child}
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}
