import { k8sListResource } from '@openshift/dynamic-plugin-sdk-utils';
import { NIMAccountModel } from '#~/api/models';
import { ConfigMapKind, NIMAccountKind } from '#~/k8sTypes';
import { getConfigMap } from './configMaps';

export const listNIMAccounts = async (namespace: string): Promise<NIMAccountKind[]> =>
  k8sListResource<NIMAccountKind>({
    model: NIMAccountModel,
    queryOptions: {
      ns: namespace,
    },
  }).then((listResource) => listResource.items);

export const getNIMAccount = async (namespace: string): Promise<NIMAccountKind | undefined> => {
  const accounts = await listNIMAccounts(namespace);
  // Find the account with the name we expect 'odh-nim-account'. Fallback to one we don't know the name of.
  let account: NIMAccountKind | undefined;
  for (const a of accounts) {
    if (a.metadata.name === 'odh-nim-account') {
      account = a;
      break;
    }
    account = a;
  }
  return account;
};

export const getNIMConfigMap = async (namespace: string): Promise<ConfigMapKind | undefined> => {
  const account = await getNIMAccount(namespace);

  if (!account || !account.status?.nimConfig?.name) {
    return undefined;
  }

  const configMap = await getConfigMap(namespace, account.status.nimConfig.name);
  return configMap;
};
