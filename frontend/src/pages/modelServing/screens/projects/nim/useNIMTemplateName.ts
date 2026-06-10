import * as React from 'react';
import { fetchNIMAccountTemplateName } from '#~/pages/modelServing/screens/projects/nim/nimUtils';

export const useNIMTemplateName = (namespace: string): string | undefined => {
  const [templateName, setTemplateName] = React.useState<string>();

  React.useEffect(() => {
    const fetchTemplateName = async () => {
      const template = await fetchNIMAccountTemplateName(namespace);
      setTemplateName(template);
    };

    fetchTemplateName();
  }, [namespace]);

  return templateName;
};
