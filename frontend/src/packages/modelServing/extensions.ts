import { SupportedArea } from '~/concepts/areas';
import { ProjectDetailsTab } from '~/plugins/extension-points';

const extensions: ProjectDetailsTab[] = [
  {
    type: 'app.project-details/tab',
    properties: {
      id: 'model-server', // same value as ProjectSectionID.MODEL_SERVER
      title: 'Models',
      component: () => import('./src/ModelServingProjectTab'),
    },
    flags: {
      required: [SupportedArea.MODEL_SERVING_EXTENSION],
    },
  },
];

export default extensions;
