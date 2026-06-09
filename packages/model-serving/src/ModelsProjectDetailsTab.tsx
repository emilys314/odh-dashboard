import React from 'react';
import { ProjectDetailsContext } from '@odh-dashboard/internal/pages/projects/ProjectDetailsContext';
import { LazyCodeRefComponent, useExtensions } from '@odh-dashboard/plugin-core';
import DetailsSection from '@odh-dashboard/internal/pages/projects/screens/detail/DetailsSection';
import { ProjectSectionID } from '@odh-dashboard/internal/pages/projects/screens/detail/types';
import {
  ModelServingPlatform,
  useProjectServingPlatform,
} from './concepts/useProjectServingPlatform';
import { ModelDeploymentsProvider } from './concepts/ModelDeploymentsContext';
import ModelsProjectDetailsView from './components/projectDetails/ModelsProjectDetailsView';
import { useAvailableProjectPlatforms } from './concepts/useAvailableProjectPlatforms';
import { isModelServingPlatformExtension } from '../extension-points';

const LoadingSection: React.FC<{ error?: Error }> = ({ error }) => (
  <DetailsSection
    id={ProjectSectionID.MODEL_SERVER}
    isLoading
    isEmpty={false}
    emptyState={null}
    loadError={error}
  >
    {undefined}
  </DetailsSection>
);

const ModelsProjectDetailsTab: React.FC = () => {
  const allPlatforms = useExtensions<ModelServingPlatform>(isModelServingPlatformExtension);

  const { currentProject } = React.useContext(ProjectDetailsContext);

  const { activePlatform } = useProjectServingPlatform(currentProject, allPlatforms);

  const {
    data: availablePlatforms,
    loaded: availablePlatformsLoaded,
    error: availablePlatformsError,
  } = useAvailableProjectPlatforms(currentProject.metadata.name);

  if (!availablePlatformsLoaded || !currentProject.metadata.name) {
    return <LoadingSection error={availablePlatformsError} />;
  }
  // TODO: remove this once modelmesh and nim are fully supported plugins
  if (activePlatform?.properties.backport?.ModelsProjectDetailsTab) {
    return (
      <LazyCodeRefComponent
        component={activePlatform.properties.backport.ModelsProjectDetailsTab}
        fallback={<LoadingSection />}
      />
    );
  }

  return (
    <ModelDeploymentsProvider projects={[currentProject]}>
      <ModelsProjectDetailsView project={currentProject} platforms={availablePlatforms} />
    </ModelDeploymentsProvider>
  );
};

export default ModelsProjectDetailsTab;
