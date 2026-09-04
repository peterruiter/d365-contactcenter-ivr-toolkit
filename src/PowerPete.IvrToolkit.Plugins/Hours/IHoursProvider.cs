using System;
using System.Collections.Generic;
using PowerPete.IvrToolkit.Model;

namespace PowerPete.IvrToolkit.Hours
{
    /// <summary>
    /// Two providers exist on purpose.
    ///
    /// OperatingHoursProvider reads the native msdyn_operatinghour calendar, which is the
    /// right answer when the client already maintains hours there. That schema is internal
    /// and has changed between waves, so it sits behind this interface and nothing else
    /// in the toolkit knows about it.
    ///
    /// ConfigHoursProvider reads the toolkit's own pwrp_queuehours and pwrp_holiday tables.
    /// Slower to set up, immune to platform schema drift, and easy for a client admin to edit.
    ///
    /// Pick per queue on the pwrp_queueprofile record.
    /// </summary>
    public interface IHoursProvider
    {
        List<DayHours> GetHours(QueueRef queue, DateTime fromLocal, int days);
    }
}
