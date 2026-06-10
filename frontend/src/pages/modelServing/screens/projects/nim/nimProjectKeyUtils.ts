import React from 'react';
import { getNIMAccount } from '#~/api/index';
import { K8sCondition, NIMAccountKind } from '#~/k8sTypes';
import useFetch, { FetchStateObject } from '#~/utilities/useFetch';

export const isAccountReady = (account: NIMAccountKind): boolean => {
  const conditions = account.status?.conditions ?? [];
  return conditions.some((c: K8sCondition) => c.type === 'AccountStatus' && c.status === 'True');
};

export const isProjectNIMAccountReady = async (namespace?: string): Promise<boolean> => {
  if (!namespace) {
    return false;
  }

  const account = await getNIMAccount(namespace);

  if (!account) {
    return false;
  }

  return isAccountReady(account);
};

export const useIsNIMProjectKeyEnabled = (namespace?: string): FetchStateObject<boolean> => {
  const callback = React.useCallback(async (): Promise<boolean> => {
    return isProjectNIMAccountReady(namespace);
  }, [namespace]);

  return useFetch(callback, false);
};
