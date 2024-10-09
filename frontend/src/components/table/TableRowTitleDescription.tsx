import * as React from 'react';
import { K8sResourceCommon } from '@openshift/dynamic-plugin-sdk-utils';
import MarkdownView from '~/components/MarkdownView';
import ResourceNameTooltip from '~/components/ResourceNameTooltip';
import TruncatedText from '~/components/TruncatedText';

type TableRowTitleDescriptionProps = {
  title: React.ReactNode;
  boldTitle?: boolean;
  titleIcon?: React.ReactNode;
  resource?: K8sResourceCommon;
  subtitle?: React.ReactNode;
  description?: React.ReactNode;
  descriptionAsMarkdown?: boolean;
  truncateDescriptionLines?: number;
  label?: React.ReactNode;
  wrapResourceTitle?: boolean;
};

const TableRowTitleDescription: React.FC<TableRowTitleDescriptionProps> = ({
  title,
  boldTitle = true,
  titleIcon,
  description,
  resource,
  subtitle,
  descriptionAsMarkdown,
  truncateDescriptionLines,
  label,
  wrapResourceTitle = true,
}) => {
  let descriptionNode: React.ReactNode;
  if (description) {
    descriptionNode =
      descriptionAsMarkdown && typeof description === 'string' ? (
        <MarkdownView conciseDisplay markdown={description} />
      ) : (
        <span
          data-testid="table-row-title-description"
          style={{ color: 'var(--pf-v5-global--Color--200)' }}
        >
          {truncateDescriptionLines !== undefined && typeof description === 'string' ? (
            <TruncatedText maxLines={truncateDescriptionLines} content={description} />
          ) : (
            description
          )}
        </span>
      );
  }

  return (
    <div>
      <div data-testid="table-row-title" className={boldTitle ? 'pf-v5-u-font-weight-bold' : ''}>
        {resource ? (
          <ResourceNameTooltip resource={resource} wrap={wrapResourceTitle}>
            {title}
          </ResourceNameTooltip>
        ) : (
          title
        )}
        {titleIcon}
      </div>
      {subtitle}
      {descriptionNode}
      {label}
    </div>
  );
};

export default TableRowTitleDescription;
