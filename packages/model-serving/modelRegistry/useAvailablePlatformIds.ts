import React from 'react';
import { useAvailableProjectPlatforms } from '../src/concepts/useAvailableProjectPlatforms';

/**
 * Returns the available cluster platforms.
 */
const useAvailablePlatformIds = (): string[] => {
  const { data: availablePlatforms } = useAvailableProjectPlatforms(null);

  return React.useMemo(() => availablePlatforms.map((p) => p.properties.id), [availablePlatforms]);
};

export default useAvailablePlatformIds;
