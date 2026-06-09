import React from 'react';
import { listNIMAccounts } from '#~/api/index.ts';
import { K8sCondition, NIMAccountKind } from '#~/k8sTypes.ts';
import useFetch, { FetchStateObject } from '#~/utilities/useFetch';

export const isAccountReady = (account: NIMAccountKind): boolean => {
  const conditions = account.status?.conditions ?? [];
  return conditions.some((c: K8sCondition) => c.type === 'AccountStatus' && c.status === 'True');
};

export const isProjectNIMAccountReady = async (namespace?: string): Promise<boolean> => {
  if (!namespace) {
    return false;
  }

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
