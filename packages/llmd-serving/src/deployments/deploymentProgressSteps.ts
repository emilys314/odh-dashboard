import React from 'react';
import type {
  DeploymentProgressStep,
  DeploymentProgressStepStatus,
} from '@odh-dashboard/model-serving/extension-points';
import type { LLMdDeployment, LLMInferenceServiceKind } from '../types';

type ConditionInfo = {
  status?: string;
  reason?: string;
  message?: string;
  lastTransitionTime?: string;
};

const getCondition = (
  llmisvc: LLMInferenceServiceKind,
  conditionType: string,
): ConditionInfo | undefined => llmisvc.status?.conditions?.find((c) => c.type === conditionType);

const conditionToStatus = (condition: ConditionInfo | undefined): DeploymentProgressStepStatus => {
  if (!condition) {
    return 'pending';
  }
  if (condition.status === 'True') {
    return 'success';
  }
  if (condition.reason === 'ProgressDeadlineExceeded') {
    return 'danger';
  }
  if (condition.reason === 'Stopped') {
    return 'pending';
  }
  return 'pending';
};

const stepStatus = (ready: boolean, error: boolean): DeploymentProgressStepStatus => {
  if (error) {
    return 'danger';
  }
  return ready ? 'success' : 'pending';
};

export const useLLMdProgressSteps = (deployment: LLMdDeployment): DeploymentProgressStep[] => {
  const { model: llmisvc } = deployment;

  return React.useMemo(() => {
    const isStopped = llmisvc.metadata.annotations?.['serving.kserve.io/stop'] === 'true';
    const readyCondition = getCondition(llmisvc, 'Ready');
    const mainWorkloadCondition = getCondition(llmisvc, 'MainWorkloadReady');
    const routerCondition = getCondition(llmisvc, 'RouterReady');
    const schedulerCondition = getCondition(llmisvc, 'SchedulerWorkloadReady');
    const httpRoutesCondition = getCondition(llmisvc, 'HTTPRoutesReady');
    const inferencePoolCondition = getCondition(llmisvc, 'InferencePoolReady');
    const presetsCondition = getCondition(llmisvc, 'PresetsCombined');
    const workloadsCondition = getCondition(llmisvc, 'WorkloadsReady');

    const isReady = readyCondition?.status === 'True';
    const mainWorkloadReady = mainWorkloadCondition?.status === 'True';
    const mainWorkloadFailed =
      mainWorkloadCondition?.reason === 'ProgressDeadlineExceeded' ||
      mainWorkloadCondition?.reason === 'MinimumReplicasUnavailable';
    const routerReady = routerCondition?.status === 'True';
    const routerFailed = routerCondition?.reason === 'ProgressDeadlineExceeded';

    return [
      {
        id: 'deployment-requested',
        title: 'Deployment requested',
        status: isStopped ? 'pending' : 'success',
        timestamp: llmisvc.metadata.creationTimestamp,
      },
      {
        id: 'presets-combined',
        title: 'Presets combined',
        status: conditionToStatus(presetsCondition),
        description: presetsCondition?.status === 'False' ? presetsCondition.message : undefined,
        timestamp: presetsCondition?.lastTransitionTime,
      },
      {
        id: 'model-workload',
        title: 'Model workload',
        status: stepStatus(mainWorkloadReady, mainWorkloadFailed),
        description: mainWorkloadReady ? undefined : mainWorkloadCondition?.message,
        timestamp: mainWorkloadCondition?.lastTransitionTime,
        children: workloadsCondition
          ? [
              {
                id: 'main-workload-ready',
                title: 'Main workload ready',
                status: conditionToStatus(mainWorkloadCondition),
                description:
                  mainWorkloadCondition?.status === 'False'
                    ? mainWorkloadCondition.message
                    : undefined,
                timestamp: mainWorkloadCondition?.lastTransitionTime,
              },
            ]
          : undefined,
      },
      {
        id: 'router-scheduler',
        title: 'Router / scheduler',
        status: stepStatus(routerReady, routerFailed),
        description: routerReady ? undefined : routerCondition?.message,
        timestamp: routerCondition?.lastTransitionTime,
        children: [
          {
            id: 'scheduler-workload-ready',
            title: 'Scheduler workload ready',
            status: conditionToStatus(schedulerCondition),
            description:
              schedulerCondition?.status === 'False' ? schedulerCondition.message : undefined,
            timestamp: schedulerCondition?.lastTransitionTime,
          },
          {
            id: 'http-routes-ready',
            title: 'HTTP routes ready',
            status: conditionToStatus(httpRoutesCondition),
            timestamp: httpRoutesCondition?.lastTransitionTime,
          },
          {
            id: 'inference-pool-ready',
            title: 'Inference pool ready',
            status: conditionToStatus(inferencePoolCondition),
            timestamp: inferencePoolCondition?.lastTransitionTime,
          },
        ],
      },
      {
        id: 'deployment-ready',
        title: 'Deployment ready',
        status: stepStatus(isReady, readyCondition?.status === 'False' && !isStopped),
        description: readyCondition?.status === 'False' ? readyCondition.message : undefined,
        timestamp: readyCondition?.lastTransitionTime,
      },
    ];
  }, [llmisvc]);
};
