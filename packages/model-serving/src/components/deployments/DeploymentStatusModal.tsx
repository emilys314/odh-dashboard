/* eslint-disable @odh-dashboard/no-restricted-imports */
import React from 'react';
import {
  Content,
  Flex,
  FlexItem,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
  ModalVariant,
  ProgressStep,
  ProgressStepper,
  ProgressStepVariant,
  Stack,
  StackItem,
} from '@patternfly/react-core';
import { ResolvedExtension } from '@openshift/dynamic-plugin-sdk';
import { ModelStatusIcon } from '@odh-dashboard/internal/concepts/modelServing/ModelStatusIcon';
import { ModelDeploymentState } from '@odh-dashboard/internal/pages/modelServing/screens/types';
import { getDisplayNameFromK8sResource } from '@odh-dashboard/internal/concepts/k8s/utils';
import { useResolvedDeploymentExtension } from '../../concepts/extensionUtils';
import {
  Deployment,
  DeploymentProgressStep,
  isModelServingDeploymentProgressSteps,
  ModelServingDeploymentProgressStepsExtension,
} from '../../../extension-points';
import './DeploymentStatusModal.scss';

const progressStepVariants: Record<DeploymentProgressStep['status'], ProgressStepVariant> = {
  pending: ProgressStepVariant.pending,
  success: ProgressStepVariant.success,
  danger: ProgressStepVariant.danger,
  warning: ProgressStepVariant.warning,
  info: ProgressStepVariant.info,
};

type DeploymentStatusModalProps = {
  deployment: Deployment;
  onClose: () => void;
  buttons: React.ReactNode;
};

const formatTimestamp = (ts: string): string => {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) {
    return ts;
  }
  return date.toLocaleString();
};

const buildDescription = (step: DeploymentProgressStep): string | undefined => {
  const parts: string[] = [];
  if (step.timestamp) {
    parts.push(formatTimestamp(step.timestamp));
  }
  if (step.description) {
    parts.push(step.description);
  }
  return parts.length > 0 ? parts.join(' — ') : undefined;
};

const ProgressStepsList: React.FC<{ steps: DeploymentProgressStep[] }> = ({ steps }) => (
  <ProgressStepper isVertical data-testid="deployment-progress-steps">
    {steps.map((step) => (
      <ProgressStep
        key={step.id}
        variant={progressStepVariants[step.status]}
        aria-label={step.status}
        id={step.id}
        titleId={`${step.id}-title`}
        description={buildDescription(step)}
        data-testid={`progress-step-${step.id}`}
      >
        {step.title}
        {step.children && step.children.length > 0 ? (
          <ProgressStepsList steps={step.children} />
        ) : null}
      </ProgressStep>
    ))}
  </ProgressStepper>
);

type ResolvedProgressContentProps = {
  deployment: Deployment;
  extension: ResolvedExtension<ModelServingDeploymentProgressStepsExtension>;
};

const ResolvedProgressContent: React.FC<ResolvedProgressContentProps> = ({
  deployment,
  extension,
}) => {
  const progressSteps = extension.properties.useProgressSteps(deployment);

  if (progressSteps.length === 0) {
    return (
      <Content data-testid="no-progress-steps">
        No progress information available for this deployment.
      </Content>
    );
  }

  return (
    <Flex direction={{ default: 'column' }} gap={{ default: 'gapMd' }} style={{ height: '100%' }}>
      <FlexItem flex={{ default: 'flex_1' }} style={{ overflowY: 'scroll', minHeight: 0 }}>
        <ProgressStepsList steps={progressSteps} />
      </FlexItem>
    </Flex>
  );
};

const DeploymentStatusModal: React.FC<DeploymentStatusModalProps> = ({
  deployment,
  onClose,
  buttons,
}) => {
  const [progressStepsExtension, extensionLoaded] = useResolvedDeploymentExtension(
    isModelServingDeploymentProgressSteps,
    deployment,
  );

  const renderProgress = () => {
    if (!extensionLoaded) {
      return <Content>Loading progress...</Content>;
    }
    if (!progressStepsExtension) {
      return (
        <Content data-testid="no-progress-steps">
          No progress information available for this deployment.
        </Content>
      );
    }
    return <ResolvedProgressContent deployment={deployment} extension={progressStepsExtension} />;
  };

  return (
    <Modal
      appendTo={document.body}
      variant={ModalVariant.small}
      isOpen
      onClose={onClose}
      data-testid="deployment-status-modal"
    >
      <ModalHeader
        data-testid="deployment-status-modal-header"
        title={
          <Flex gap={{ default: 'gapMd' }} alignItems={{ default: 'alignItemsCenter' }}>
            <FlexItem>Deployment status</FlexItem>
            <FlexItem>
              <ModelStatusIcon
                state={deployment.status?.state ?? ModelDeploymentState.UNKNOWN}
                stoppedStates={deployment.status?.stoppedStates}
              />
            </FlexItem>
          </Flex>
        }
      />
      <ModalBody className="deployment-status-modal__content-height">
        <Stack hasGutter style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
          <StackItem>
            <Content component="p" data-testid="deployment-status-name">
              {getDisplayNameFromK8sResource(deployment.model)}
            </Content>
          </StackItem>
          <StackItem isFilled className="deployment-status-modal__filled-stack-item">
            {renderProgress()}
          </StackItem>
        </Stack>
      </ModalBody>
      <ModalFooter>{buttons}</ModalFooter>
    </Modal>
  );
};

export default DeploymentStatusModal;
