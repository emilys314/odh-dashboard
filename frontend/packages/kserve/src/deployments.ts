// eslint-disable-next-line import/no-extraneous-dependencies
import {
  InferenceServiceKind,
  K8sAPIOptions,
  ProjectKind,
  ServingRuntimeKind,
} from '@odh-dashboard/internal/k8sTypes';
// eslint-disable-next-line import/no-extraneous-dependencies
import { listInferenceService, listServingRuntimes } from '@odh-dashboard/internal/api/index';
// eslint-disable-next-line import/no-extraneous-dependencies
import useK8sWatchResourceList from '@odh-dashboard/internal/utilities/useK8sWatchResourceList';
// eslint-disable-next-line import/no-extraneous-dependencies
import { groupVersionKind } from '@odh-dashboard/internal/api/k8sUtils';
// eslint-disable-next-line import/no-extraneous-dependencies
import {
  InferenceServiceModel,
  ServingRuntimeModel,
} from '@odh-dashboard/internal/api/models/kserve';
import { Deployment } from '@odh-dashboard/model-serving/extension-points';
import { K8sResourceCommon } from '@openshift/dynamic-plugin-sdk-utils';

export type KServeDeployment = Deployment<InferenceServiceKind, ServingRuntimeKind>;
export const isKServeDeployment = (
  deployment: Deployment<K8sResourceCommon, K8sResourceCommon>,
): deployment is KServeDeployment => deployment.modelServingPlatformId === 'kserve';

export const listDeployments = async (
  project: ProjectKind,
  opts: K8sAPIOptions,
): Promise<KServeDeployment[]> => {
  const inferenceServiceList = await listInferenceService(
    project.metadata.name,
    'opendatahub.io/dashboard=true',
    opts,
  );
  const servingRuntimeList = await listServingRuntimes(
    project.metadata.name,
    'opendatahub.io/dashboard=true',
    opts,
  );

  return inferenceServiceList.map((inferenceService) => ({
    modelServingPlatformId: 'kserve',
    model: inferenceService,
    server: servingRuntimeList.find(
      (servingRuntime) =>
        servingRuntime.metadata.name === inferenceService.spec.predictor.model?.runtime,
    ),
  }));
};

export const useWatchDeployments = (
  project: ProjectKind,
  // opts: K8sAPIOptions,
): [Deployment[] | undefined, boolean, Error | undefined] => {
  const [inferenceServiceList, inferenceServiceLoaded, inferenceServiceError]: [
    InferenceServiceKind[],
    boolean,
    Error | undefined,
  ] = useK8sWatchResourceList(
    {
      isList: true,
      groupVersionKind: groupVersionKind(InferenceServiceModel),
      namespace: project.metadata.name,
    },
    InferenceServiceModel,
  );

  const [servingRuntimeList, servingRuntimeLoaded, servingRuntimeError]: [
    ServingRuntimeKind[],
    boolean,
    Error | undefined,
  ] = useK8sWatchResourceList(
    {
      isList: true,
      groupVersionKind: groupVersionKind(ServingRuntimeModel),
      namespace: project.metadata.name,
    },
    ServingRuntimeModel,
  );

  const deployments = inferenceServiceList.map((inferenceService) => ({
    modelServingPlatformId: 'kserve',
    model: inferenceService,
    server: servingRuntimeList.find(
      (servingRuntime) =>
        servingRuntime.metadata.name === inferenceService.spec.predictor.model?.runtime,
    ),
  }));

  return [
    deployments,
    inferenceServiceLoaded && servingRuntimeLoaded,
    inferenceServiceError || servingRuntimeError,
  ];
};
