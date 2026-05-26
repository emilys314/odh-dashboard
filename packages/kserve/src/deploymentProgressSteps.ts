import React from 'react';
import type { InferenceServiceKind } from '@odh-dashboard/internal/k8sTypes';
import type {
  DeploymentProgressStep,
  DeploymentProgressStepStatus,
} from '@odh-dashboard/model-serving/extension-points';
import type { KServeDeployment } from './deployments';

type ConditionInfo = {
  status: string;
  reason: string | undefined;
  message: string | undefined;
  lastTransitionTime: string | undefined;
};

const getCondition = (
  isvc: InferenceServiceKind,
  conditionType: string,
): ConditionInfo | undefined => {
  const condition = isvc.status?.conditions?.find((c) => c.type === conditionType);
  if (!condition) {
    return undefined;
  }
  return {
    status: condition.status,
    reason:
      'reason' in condition && typeof condition.reason === 'string' ? condition.reason : undefined,
    message:
      'message' in condition && typeof condition.message === 'string'
        ? condition.message
        : undefined,
    lastTransitionTime: condition.lastTransitionTime,
  };
};

const stepStatus = (ready: boolean, error: boolean): DeploymentProgressStepStatus => {
  if (error) {
    return 'danger';
  }
  return ready ? 'success' : 'pending';
};

export const useKServeProgressSteps = (deployment: KServeDeployment): DeploymentProgressStep[] => {
  const { model: isvc } = deployment;

  return React.useMemo(() => {
    const isStopped = isvc.metadata.annotations?.['serving.kserve.io/stop'] === 'true';
    const modelState =
      isvc.status?.modelStatus?.states?.targetModelState ??
      isvc.status?.modelStatus?.states?.activeModelState ??
      '';
    const readyCondition = getCondition(isvc, 'Ready');
    const predictorCondition = getCondition(isvc, 'PredictorReady');
    const ingressCondition = getCondition(isvc, 'IngressReady');

    const isReady = readyCondition?.status === 'True';
    const isPredictorReady = predictorCondition?.status === 'True';
    const isIngressReady = ingressCondition?.status === 'True';
    const isModelLoaded = modelState === 'Loaded';
    const isModelFailed = modelState === 'FailedToLoad';
    const isProgressDeadlineExceeded = predictorCondition?.reason === 'ProgressDeadlineExceeded';

    return [
      {
        id: 'deployment-requested',
        title: 'Deployment requested',
        status: isStopped ? 'pending' : 'success',
        timestamp: isvc.metadata.creationTimestamp,
      },
      {
        id: 'predictor-ready',
        title: 'Predictor ready',
        status: stepStatus(isPredictorReady, Boolean(isProgressDeadlineExceeded)),
        description: isPredictorReady ? undefined : predictorCondition?.message,
        timestamp: predictorCondition?.lastTransitionTime,
      },
      // {
      //   id: 'model-loaded',
      //   title: 'Model loaded',
      //   status: stepStatus(isModelLoaded, isModelFailed),
      //   description: isModelFailed ? isvc.status?.modelStatus?.lastFailureInfo?.reason : undefined,
      //   timestamp:
      //     isvc.status?.modelStatus?.lastFailureInfo?.time ?? predictorCondition?.lastTransitionTime,
      // },
      {
        id: 'ingress-ready',
        title: 'Ingress ready',
        status: stepStatus(isIngressReady, false),
        timestamp: ingressCondition?.lastTransitionTime,
      },
      {
        id: 'deployment-ready',
        title: 'Deployment ready',
        status: stepStatus(isReady, readyCondition?.status === 'False' && !isStopped),
        description: readyCondition?.status === 'False' ? readyCondition.message : undefined,
        timestamp: readyCondition?.lastTransitionTime,
      },
    ];
  }, [isvc]);
};
