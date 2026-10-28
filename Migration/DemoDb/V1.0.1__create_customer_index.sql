-- Flyway-versioned migration. Naming: V<version>__<description>.sql
-- The pipeline validates ordering before promoting staging to production.
CREATE NONCLUSTERED INDEX [IX_Customer_DisplayName]
    ON [dbo].[Customer] ([DisplayName] ASC);
