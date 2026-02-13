import { StreamClient, APIResponse } from './client';
export type ActivityToDelete = {
    id: string;
    remove_from_feeds: string[];
};
export type ExportIDsResult = {
    activity_count: number;
    reaction_count: number;
    activity_ids?: string[];
    reaction_ids?: string[];
    user_id?: string;
};
export type ExportIDsResponse = APIResponse & {
    export?: ExportIDsResult;
};
export declare function deleteActivities(this: StreamClient, activities: ActivityToDelete[]): Promise<APIResponse>;
export declare function deleteReactions(this: StreamClient, ids: string[]): Promise<APIResponse>;
export declare function exportUserActivitiesAndReactionIDs(this: StreamClient, userId: string): Promise<ExportIDsResponse>;
declare const _default: {
    deleteActivities: typeof deleteActivities;
    deleteReactions: typeof deleteReactions;
    exportUserActivitiesAndReactionIDs: typeof exportUserActivitiesAndReactionIDs;
};
export default _default;
//# sourceMappingURL=data_privacy.d.ts.map